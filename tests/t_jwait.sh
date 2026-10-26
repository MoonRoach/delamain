#!/bin/bash
# jlog / jwait: baseline, own-tag exclusion, rewrite without replay, filters, file sources, partial lines,
# --since replay, alarms, usage errors.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a; O=$AGENT_HUB_HOME
J=$(journal stage-a)
$B/jlog --tag old "old line before the first run" >/dev/null
# 1. first run: baseline; a line from another process wakes it
# the writer waits until jwait has baselined: a fixed sleep raced a jwait that started late on a loaded machine
( armed $O/o1.out; $B/jlog --tag hub-16-builder "DONE builder finished" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --settle 1 --for 30s > $O/o1.out 2>&1; rc=$?
check $rc 0 "positive: line from another process delivered"
grep -q 'DONE builder' $O/o1.out && ! grep -q 'old line' $O/o1.out; check $? 0 "baseline: old line not delivered"
grep -q 'first run of \[hub-16\]' $O/o1.out; check $? 0 "baseline run says it marked lines as seen"
# 2. own tag and own sub-tag ignored, sibling tag delivered
( sleep 1; $B/jlog --tag hub-16 "own line" >/dev/null; $B/jlog --tag hub-16/r7 "own sub-line" >/dev/null; sleep 2; $B/jlog --tag steward "MERGED #700" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --settle 1 --for 30s > $O/o2.out 2>&1; rc=$?
check $rc 0 "sibling line delivered"
! grep -q 'own' $O/o2.out; check $? 0 "negative: own tag and sub-tag ignored"
grep -q 'MERGED #700' $O/o2.out; check $? 0 "MERGED line present"
# 3. rewrite/replay: same content rewritten (new inode) -> nothing delivered -> alarm
cp $J $J.tmp && mv $J.tmp $J
HUB_TAG=hub-16 $B/jwait --journal --settle 1 --for 4s --note "replay check" > $O/o3.out 2>&1; rc=$?
check $rc 3 "negative: replayed journal after rewrite delivers nothing (alarm)"
grep -q '^ALARM replay check' $O/o3.out; check $? 0 "ALARM line printed"
# 4. lines appended while nobody waits are delivered on the next run
$B/jlog --tag qa "BLOCKED need the staging env" >/dev/null
HUB_TAG=hub-16 $B/jwait --journal --settle 0 --for 5s > $O/o4.out 2>&1; rc=$?
check $rc 0 "line appended between runs delivered"
grep -q 'BLOCKED need the staging env' $O/o4.out; check $? 0 "…with its text"
# 5. filters: --match / --tag @mention; non-matching ignored
( sleep 1; $B/jlog --tag builder "just progress" >/dev/null; sleep 1; $B/jlog --tag builder "@hub-16 QUESTION about #701" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --tag hub-16 --match 'MERGED|STOP' --settle 1 --for 20s > $O/o5.out 2>&1; rc=$?
check $rc 0 "@mention delivered"
! grep -q 'just progress' $O/o5.out; check $? 0 "negative: non-matching line filtered"
# 6. file source: a question already in the file before start is delivered; settle batches
F=$O/script.log; printf 'step 1 ok\nAWAITING ANSWER [go] continue?\n' > $F
( sleep 1; echo 'AWAITING ANSWER [go2] and this?' >> $F ) &
$B/jwait --file $F --match 'AWAITING ANSWER' --settle 3 --for 20s --caller t6 > $O/o6.out 2>&1; rc=$?
check $rc 0 "file source delivered"
check "$(grep -c 'AWAITING ANSWER' $O/o6.out)" 2 "settle batched both questions into one block"
$B/jwait --file $F --match 'AWAITING ANSWER' --settle 0 --for 3s --caller t6 > $O/o7.out 2>&1; rc=$?
check $rc 3 "negative: same file lines not re-delivered"
# 7. pure alarm, a few seconds ahead: HH:MM:SS and ISO with seconds fire at the second, not at the next minute.
# Every alarm runs under a hard limit: a clock time that has already passed when jwait parses it (a loaded machine)
# means tomorrow for HH:MM:SS, and the runner must fail, not wait a day.
hms=$(utc_hms 6); case $hms in *:00) hms=$(utc_hms 7);; esac   # a :00 deadline prints without seconds
t0=$(date +%s)
bounded 45 $B/jwait --until "$hms" --note "check the nightly import" > $O/o8.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check $rc 3 "pure alarm (HH:MM:SS) exit 3"; grep -q '^ALARM check the nightly import' $O/o8.out; check $? 0 "pure alarm text"
[ $el -le 30 ]; check $? 0 "HH:MM:SS fires within seconds, not at the next minute (${el}s)"
grep -Eq 'deadline [0-9.]+ [0-9]{2}:[0-9]{2}:[0-9]{2}\)' $O/o8.out; check $? 0 "the alarm line shows the deadline with seconds"
# ISO with seconds is a date: one already past fires at once whatever the start delay, one ahead waits for its second
t0=$(date +%s)
bounded 45 $B/jwait --until "$(utc_iso_s -2)" --note "iso past" > $O/o8c.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check $rc 3 "ISO with seconds already past: alarm exit 3"; grep -q '^ALARM iso past' $O/o8c.out; check $? 0 "ISO past alarm text"
[ $el -le 10 ]; check $? 0 "ISO past fires at once, not tomorrow (${el}s)"
t0=$(date +%s)
bounded 45 $B/jwait --until "$(utc_iso_s 5)" --note "iso alarm" > $O/o8b.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check $rc 3 "pure alarm (ISO with seconds) exit 3"; grep -q '^ALARM iso alarm' $O/o8b.out; check $? 0 "ISO alarm text"
[ $el -ge 2 ] && [ $el -le 30 ]; check $? 0 "ISO with seconds waits for its second, not the next minute (${el}s)"
# HH:MM keeps its meaning: the start of that minute, a past one is tomorrow; HH:MM:SS the same by the second
python3 - "$B" <<'PY'
import datetime as dt, sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
base = dt.datetime(2026, 10, 4, 20, 23, 30, 500, tzinfo=hc.TZ)
def pd(raw): return hc.parse_deadline(raw, base)
def at(*a): return dt.datetime(*a, tzinfo=hc.TZ)
assert pd("20:24") == at(2026, 10, 4, 20, 24, 0), pd("20:24")
assert pd("20:23") == at(2026, 10, 5, 20, 23, 0), pd("20:23")
assert pd("20:23:45") == at(2026, 10, 4, 20, 23, 45), pd("20:23:45")
assert pd("20:23:30") == at(2026, 10, 5, 20, 23, 30), pd("20:23:30")
assert pd("9:05:07") == at(2026, 10, 5, 9, 5, 7), pd("9:05:07")
assert pd("2026-10-04T20:23:45") == at(2026, 10, 4, 20, 23, 45), pd("2026-10-04T20:23:45")
assert pd("2026-10-04T20:23") == at(2026, 10, 4, 20, 23, 0), pd("2026-10-04T20:23")
for bad in ("20:23:4", "25:00", "20:61", "20:23:61", "20:23:45:01", "soon"):
    try: pd(bad)
    except hc.UsageError: continue
    raise AssertionError(f"accepted {bad!r}")
PY
check $? 0 "parse_deadline: HH:MM unchanged, HH:MM:SS and ISO with seconds accepted, malformed refused"
$B/jwait --until 20:23:61 >/dev/null 2>&1; check $? 2 "usage: --until with seconds out of range"
# 8. usage errors
$B/jwait >/dev/null 2>&1; check $? 2 "usage: no source, no deadline"
$B/jlog "no tag" >/dev/null 2>&1; check $? 2 "usage: jlog without tag"
# 9. an in-place edit that grows a watched file delivers only the inserted line
F=$O/p.log
printf -- '- 10:00 [qa] line A\n- 10:01 [qa] line B\n- 10:02 [qa] line C\n' > $F
$B/jwait --file $F --settle 0 --for 3s --caller r1 >/dev/null 2>&1
( sleep 1.5; python3 -c "
p='$F'; s=open(p).read(); fh=open(p,'r+'); fh.seek(0); fh.write('- 09:59 [qa] line NEW\n'+s); fh.close()" ) &
$B/jwait --file $F --settle 1 --for 10s --caller r1 > $O/o9.out 2>&1
check "$(grep -c '^p.log:' $O/o9.out)" 1 "in-place growing edit delivers only the inserted line"
grep -q 'line NEW' $O/o9.out; check $? 0 "…and it is the new line"
# 10. a new caller gets what arrived since --since (ISO), even after a baseline run
new_home
$B/jlog --tag qa "AWAITING ANSWER [go] ship it?" >/dev/null
$B/jwait --journal --match 'AWAITING ANSWER' --caller hub-17 --since "$(utc_iso -2)" --settle 0 --for 5s > $O/o10.out 2>&1; rc=$?
check $rc 0 "--since <ISO> delivers the line written before the first run"
$B/jwait --journal --caller hub-18 --settle 0 --for 2s >/dev/null 2>&1   # baseline: the line is now "seen" by hub-18
$B/jwait --journal --match 'AWAITING ANSWER' --caller hub-18 --since "$(utc_iso -2)" --settle 0 --for 4s > $O/o11.out 2>&1; rc=$?
check $rc 0 "--since after a baseline run replays the line"
grep -q 'ship it' $O/o11.out; check $? 0 "…the right line"
$B/jwait --journal --match 'AWAITING ANSWER' --caller hub-18 --settle 0 --for 3s >/dev/null 2>&1; check $? 3 "negative: without --since it stays seen"
# 11. partial last line of a --file source (a script blocked on read -p)
F=$O/go.log; printf 'step 1 ok\nAWAITING ANSWER [go] ship? (yes/no) ' > $F
$B/jwait --file $F --match 'AWAITING ANSWER' --caller p1 --settle 2 --for 20s > $O/o12.out 2>&1; rc=$?
check $rc 0 "partial: a question without a newline is delivered once stable"
grep -q 'ship?' $O/o12.out; check $? 0 "partial: …with its text"
printf '\n' >> $F
$B/jwait --file $F --match 'AWAITING ANSWER' --caller p1 --settle 1 --for 4s >/dev/null 2>&1; check $? 3 "partial: completing the line later does not deliver it again"
# 15. stage-qualified address: on stage core-c, --tag hub-30 also hears @core-c-hub-30 (how another stage's hub signs
# and answers), and nothing that merely looks like it
mkdir -p $AGENT_HUB_HOME/core-c $AGENT_HUB_HOME/dolyaq   # a stage of its own here, whatever exists in the real hub home
$B/jlog --stage core-c --tag old "baseline line" >/dev/null
( armed $AGENT_HUB_HOME/q1.out; $B/jlog --stage core-c --tag dolya-hub-4 "@dolya-hub-30 not ours" >/dev/null; $B/jlog --stage core-c --tag dolya-hub-4 "@core-c-hub-300 not ours" >/dev/null
  $B/jlog --stage core-c --tag dolya-hub-4 "@xcore-c-hub-30 not ours" >/dev/null; $B/jlog --stage core-c --tag dolya-hub-4 "@hub-300 not ours" >/dev/null ) &
HUB_TAG=hub-30 $B/jwait --journal --stage core-c --tag hub-30 --settle 1 --for 6s --caller q1 > $AGENT_HUB_HOME/q1.out 2>&1; rc=$?
check $rc 3 "negative: @dolya-hub-30, @core-c-hub-300, @xcore-c-hub-30, @hub-300 do not wake --tag hub-30 on core-c"
( armed $AGENT_HUB_HOME/q2.out; $B/jlog --stage core-c --tag dolya-hub-4 "@core-c-hub-30 your answer" >/dev/null ) &
HUB_TAG=hub-30 $B/jwait --journal --stage core-c --tag hub-30 --settle 1 --for 30s --caller q1 > $AGENT_HUB_HOME/q2.out 2>&1; rc=$?
check $rc 0 "positive: @core-c-hub-30 wakes --tag hub-30 on core-c"
grep -q 'your answer' $AGENT_HUB_HOME/q2.out; check $? 0 "…with the line"
( armed $AGENT_HUB_HOME/q3.out; $B/jlog --stage core-c --tag dolya-hub-4 "@core-c-hub QUESTION for the hub" >/dev/null ) &
HUB_TAG=hub-30 $B/jwait --journal --stage core-c --tag hub-30 --tag hub --settle 1 --for 30s --caller q1 > $AGENT_HUB_HOME/q3.out 2>&1; rc=$?
check $rc 0 "positive: --tag hub wakes on @core-c-hub"
( armed $AGENT_HUB_HOME/q4.out; $B/jlog --stage core-c --tag dolya-hub-4 "@hub-30 plain address" >/dev/null ) &
HUB_TAG=hub-30 $B/jwait --journal --stage core-c --tag hub-30 --settle 1 --for 30s --caller q1 > $AGENT_HUB_HOME/q4.out 2>&1; rc=$?
check $rc 0 "control: the plain @hub-30 still wakes"
# 16. the caller's own signature in a foreign journal does not wake it: [core-c-hub-30] (jlog's form) is excluded like [hub-30]
$B/jlog --stage dolyaq --tag old "baseline line" >/dev/null
( armed $AGENT_HUB_HOME/r1.out; $B/jlog --stage dolyaq --tag core-c-hub-30 "@hub QUESTION own line" >/dev/null; $B/jlog --stage dolyaq --tag core-c-hub-30/r2 "@hub QUESTION own sub-tag" >/dev/null; $B/jlog --stage dolyaq --tag hub-30 "@hub QUESTION own short tag" >/dev/null ) &
HUB_STAGE=core-c HUB_TAG=hub-30 $B/jwait --journal --stage dolyaq --match QUESTION --settle 1 --for 6s --caller r1 > $AGENT_HUB_HOME/r1.out 2>&1; rc=$?
check $rc 3 "negative: own [core-c-hub-30], [core-c-hub-30/r2] and [hub-30] lines do not wake the caller"
( armed $AGENT_HUB_HOME/r2.out; $B/jlog --stage dolyaq --tag dolya-hub-4 "@hub QUESTION from someone else" >/dev/null ) &
HUB_STAGE=core-c HUB_TAG=hub-30 $B/jwait --journal --stage dolyaq --match QUESTION --settle 1 --for 30s --caller r1 > $AGENT_HUB_HOME/r2.out 2>&1; rc=$?
check $rc 0 "control: another stage's QUESTION line wakes it"
( armed $AGENT_HUB_HOME/r3.out; $B/jlog --stage dolyaq --tag core-c-hub-30 "@hub QUESTION own again" >/dev/null ) &
HUB_STAGE=core-c HUB_TAG=hub-30 $B/jwait --journal --stage dolyaq --match QUESTION --include-own --settle 1 --for 30s --caller r1 > $AGENT_HUB_HOME/r3.out 2>&1; rc=$?
check $rc 0 "--include-own keeps the own signature"
O=$AGENT_HUB_HOME; J=$(journal stage-a)   # the home was renewed above
# 8. the default --for is 50m (the prompt cache lives 1 h), a setting changes it, a printed command carries it
hcfor(){ python3 - "$B" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
print(hc.jwait_for())
PY
}
secs=$(python3 - "$B" <<'PY'
import importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
loader = importlib.machinery.SourceFileLoader("jwait_cli", sys.argv[1] + "/jwait")
spec = importlib.util.spec_from_loader("jwait_cli", loader); jw = importlib.util.module_from_spec(spec); loader.exec_module(jw)
print(int(hc.parse_duration(jw.DEFAULT_FOR).total_seconds()))
PY
)
check "$secs" 3000 "default --for is 50m"
$B/jwait --help | tr '\n' ' ' | grep -q 'default --for 50m'; check $? 0 "--help says the default is 50m"
check "$(hcfor)" 50m "jwait_for(): no setting -> 50m"
check "$(AGENT_HUB_JWAIT_FOR=90m hcfor)" 90m "jwait_for(): the environment sets it"
mkdir -p $O && echo '{"AGENT_HUB_JWAIT_FOR": "20m"}' > $O/config.json
check "$(hcfor)" 20m "jwait_for(): the hub home's config.json sets it"
check "$(AGENT_HUB_JWAIT_FOR=1h30m hcfor)" 1h30m "jwait_for(): the environment wins over config.json"
check "$(AGENT_HUB_JWAIT_FOR=soon hcfor 2>$O/w1.err)" 50m "jwait_for(): an unparsable value falls back to 50m"
grep -q 'AGENT_HUB_JWAIT_FOR is not a duration' $O/w1.err; check $? 0 "…and says so on stderr"
check "$(AGENT_HUB_JWAIT_FOR=0m hcfor 2>/dev/null)" 50m "jwait_for(): a zero duration falls back to 50m"
check "$(AGENT_HUB_JWAIT_FOR=24h hcfor)" 24h "jwait_for(): 24h, the cap, is accepted"
for v in 25h 100000000d 1000000000d; do
  check "$(AGENT_HUB_JWAIT_FOR=$v hcfor 2>$O/w2.err)" 50m "jwait_for(): $v is over the cap -> 50m"
  grep -q 'AGENT_HUB_JWAIT_FOR is not a duration' $O/w2.err; check $? 0 "…with a warning, no traceback ($v)"
done
# a real run: the deadline in the start line is now + the configured wait; an explicit --for still wins
waited(){  # waited <minutes expected> <extra env...> -- <jwait args...>: run jwait, read its deadline, stop it
  local want=$1; shift; local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env ${envs[@]+"${envs[@]}"} $B/jwait "$@" > $O/wd.out 2>&1 & local pid=$!
  armed $O/wd.out; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  python3 - "$O/wd.out" "$want" <<'PY'
import datetime as dt, re, sys
m = re.search(r"until (\d\d)\.(\d\d) (\d\d):(\d\d)(?::(\d\d))?", open(sys.argv[1]).read())
now = dt.datetime.now(dt.timezone.utc)
end = now.replace(month=int(m[2]), day=int(m[1]), hour=int(m[3]), minute=int(m[4]), second=int(m[5] or 0), microsecond=0)
if end < now - dt.timedelta(days=1):  # the deadline is across New Year: the printed date has no year
    end = end.replace(year=now.year + 1)
left = (end - now).total_seconds() / 60
print("ok" if abs(left - float(sys.argv[2])) <= 1.5 else f"got {left:.1f} min")
PY
}
rm $O/config.json
check "$(waited 50 -- --journal --caller d1 --stage stage-a)" ok "a run without --for waits 50 minutes"
check "$(waited 40 AGENT_HUB_JWAIT_FOR=40m -- --journal --caller d1 --stage stage-a)" ok "AGENT_HUB_JWAIT_FOR=40m: the run waits 40 minutes"
check "$(waited 5 AGENT_HUB_JWAIT_FOR=40m -- --journal --caller d1 --stage stage-a --for 5m)" ok "an explicit --for wins over the setting"
# 9. a plugin service line (the autopilot's chain reset) does not wake a hub; a DONE line does
mkdir -p $O/stage-a; echo '{"chain": 2, "pending": null}' > $O/stage-a/auto-handoff.json
PAT=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore as hc; print(hc.status_pattern())' "$B")
( armed $O/o9.out; python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import autopilot as ap; ap.reset_chain("stage-a", "the owner spoke in the hub'"'"'s session")' "$B"
  sleep 2; $B/jlog --tag builder "DONE builder finished" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --match "$PAT" --settle 1 --for 30s --caller s9 > $O/o9.out 2>&1; rc=$?
check $rc 0 "service line: the DONE line wakes the hub"
grep -q 'DONE builder finished' $O/o9.out; check $? 0 "…and is delivered"
grep -q 'chain reset' $J; check $? 0 "the chain reset line is in the journal (readable)"
grep -q 'chain reset' $O/o9.out; check $? 1 "negative: the chain reset line does not wake a hub waiting on --tag hub"
# Canonical digest argv at the transport seam: execute the emitted command, not a copied regex.
python3 - "$B" <<'PYCONTROL'
import datetime as dt, json, os, pathlib, runpy, shlex, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root))
import hubcore as hc
hub = runpy.run_path(str(root / 'hub'), run_name='wake_control')
with tempfile.TemporaryDirectory() as tmp:
    os.environ.update(AGENT_HUB_HOME=tmp, HUB_STAGE='wake-control', HUB_TAG='hub-2',
                      AGENT_HUB_JWAIT_FOR='1s')
    os.environ.pop('AGENT_HUB_JWAIT_MATCH', None)
    pathlib.Path(tmp, 'config.json').write_text(json.dumps({'AGENT_HUB_JWAIT_MATCH': r"CUSTOM_READY|quoted 'event'"}))
    handoff = pathlib.Path(tmp, 'HANDOFF-wake-control.md')
    handoff.write_text('## Business DoD\nFinish authorized fixture work.\n## 0. First steps\nReplay events.\n')
    def emitted(since=None):
        if since:
            os.utime(handoff, (since.timestamp(), since.timestamp()))
        digest = hub['digest']('wake-control', 2, 'fixture', handoff if since else None, [])
        command = next(line for line in digest.splitlines() if line.startswith('jwait --journal '))
        argv = shlex.split(command)
        assert '--hub-events' in argv and '--match' not in argv, argv
        assert '--stream' in argv and '--for' not in argv, argv  # a Claude host streams under a Monitor (section 10)
        i = argv.index('--stream'); argv[i:i + 1] = ['--for', '1s']  # run to the first batch here
        argv[0] = str(root / 'jwait')
        return argv + ['--settle', '0', '--caller', 'digest-control']
    def run(argv, rc, present=(), absent=()):
        result = subprocess.run(argv, capture_output=True, text=True, timeout=8)
        assert result.returncode == rc, (argv, result.returncode, result.stdout, result.stderr)
        for text in present:
            assert text in result.stdout, (text, result.stdout)
        for text in absent:
            assert text not in result.stdout, (text, result.stdout)
    hc.journal_append('wake-control', 'executor', 'baseline-control')
    argv = emitted()
    run(argv, 3)  # establish the actual digest caller's cursor
    since = hc.now() - dt.timedelta(minutes=1)
    for word in ('DONE', 'STOP', 'BLOCKED', 'ENDED', 'REVIEWED', 'EXIT', 'MERGED', 'QUESTION', 'AWAITING ANSWER'):
        hc.journal_append('wake-control', 'executor', word + ' transport-control')
    hc.journal_append('wake-control', 'executor', 'CUSTOM_READY configured-control')
    hc.journal_append('wake-control', 'executor', "quoted 'event' quoting-control")
    hc.journal_append('wake-control', 'executor', '@wake-control-hub-2 addressed-control')
    hc.journal_append('wake-control', 'executor', 'neutral-control')
    hc.journal_append('wake-control', 'hub-2', 'DONE own-control')
    hc.journal_append('wake-control', 'hub-2/child', 'STOP subtag-control')
    hc.journal_append('wake-control', 'executor', '@hub-20 wrong-address-control')
    delivered = tuple(word + ' transport-control' for word in
                      ('DONE', 'STOP', 'BLOCKED', 'ENDED', 'REVIEWED', 'EXIT', 'MERGED', 'QUESTION', 'AWAITING ANSWER'))
    excluded = ('neutral-control', 'own-control', 'subtag-control', 'wrong-address-control')
    run(argv, 0, delivered + ('configured-control', 'quoting-control', 'addressed-control'), excluded)
    run(argv, 3, absent=delivered)  # consumption suppresses redelivery
    run(emitted(since), 0, delivered, excluded)  # handover --since explicitly replays seen events
    run(argv, 3)
    hc.journal_append('wake-control', 'executor', 'LEGACY_CUSTOM custom-control')
    run(argv + ['--match', 'LEGACY_CUSTOM'], 0, ('custom-control',))
    hc.journal_append('wake-control', 'executor', 'DONE legacy-terminal-control')
    hc.journal_append('wake-control', 'executor', 'LEGACY_ONLY legacy-positive-control')
    legacy = [str(root / 'jwait'), '--journal', '--stage', 'wake-control', '--caller', 'legacy-control',
              '--since', since.isoformat(), '--match', 'LEGACY_ONLY', '--settle', '0', '--for', '1s']
    run(legacy, 0, ('legacy-positive-control',), ('legacy-terminal-control',))
    tags = [str(root / 'jwait'), '--journal', '--stage', 'wake-control', '--caller', 'tags-control',
            '--since', since.isoformat(), '--tag', 'unaddressed', '--settle', '0', '--for', '1s']
    run(tags, 3, absent=delivered)  # tags alone still do not add terminal words
print('PASS digest --hub-events transport, exclusions, cursor/replay, extra words and legacy filters')
PYCONTROL
check $? 0 "canonical digest terminal transport controls"
# 10. held lines: another stage's hub and the pacer addressing @hub do not wake; they come with the next waking batch.
# --stream keeps printing batches until the deadline; tell --urgent wakes.
mkdir -p $O/stage-b
( armed $O/o10.out; $B/jlog --tag stage-b-hub-3 "@hub FYI merged my side" >/dev/null
  $B/jlog --tag pace "@hub LIMIT Codex 7d ahead — context" >/dev/null; sleep 3
  $B/jlog --tag builder "DONE builder r10" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 30s --caller s10 > $O/o10.out 2>&1; rc=$?
check $rc 0 "held: the DONE line wakes"
grep -q '^HELD (did not wake you): 2 lines' $O/o10.out; check $? 0 "…the held lines come with it, under HELD"
grep -q 'FYI merged my side' $O/o10.out && grep -q 'LIMIT Codex 7d ahead' $O/o10.out; check $? 0 "…both of them"
# held alone: no wake until the deadline, where they are printed with the ALARM
( armed $O/o11.out; $B/jlog --tag stage-b-hub-3 "@hub FYI only chatter" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 4s --note r11 --caller s10 > $O/o11.out 2>&1; rc=$?
check $rc 3 "negative: a held line alone does not wake (deadline)"
grep -q 'FYI only chatter' $O/o11.out && grep -q '^ALARM r11' $O/o11.out; check $? 0 "…it is printed with the ALARM"
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 0 --for 2s --caller s10 > $O/o11b.out 2>&1
! grep -q 'only chatter' $O/o11b.out; check $? 0 "…and is not delivered again"
# a held line killed before delivery is not lost
( armed $O/o12.out; $B/jlog --tag stage-b-hub-3 "@hub FYI survives a kill" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 60s --caller s10 > $O/o12.out 2>&1 & jp=$!
armed $O/o12.out; sleep 3; kill $jp; wait $jp 2>/dev/null
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 0 --for 2s --caller s10 > $O/o12b.out 2>&1
grep -q 'FYI survives a kill' $O/o12b.out; check $? 0 "held line of a killed waiter is delivered by the next one"
# wake words in a foreign hub's line, and a foreign hub addressing the hub by its own tag, wake
( armed $O/o13.out; $B/jlog --tag stage-b-hub-3 "@hub URGENT stop merging" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 20s --caller s10 > $O/o13.out 2>&1; rc=$?
check $rc 0 "URGENT from another hub wakes"
( armed $O/o14.out; $B/jlog --tag stage-b-hub-3 "@hub-16 please look" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 20s --caller s10 > $O/o14.out 2>&1; rc=$?
check $rc 0 "another hub addressing @hub-16 wakes"
# an unknown stage prefix is not another hub: it wakes as before
( armed $O/o15.out; $B/jlog --tag nostage-hub-3 "@hub hello" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 1 --for 20s --caller s10 > $O/o15.out 2>&1; rc=$?
check $rc 0 "a tag that names no stage wakes as before"
# --stream: two batches in one run, then the ALARM
( armed $O/o16.out; $B/jlog --tag builder "DONE first-batch" >/dev/null; sleep 4
  $B/jlog --tag builder "DONE second-batch" >/dev/null ) &
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --stream --settle 1 --for 9s --note r16 --caller s10 > $O/o16.out 2>&1; rc=$?
check $rc 3 "--stream ends at the deadline"
check "$(grep -c '^NEW: 1 lines' $O/o16.out)" 2 "--stream printed two batches"
grep -q 'first-batch' $O/o16.out && grep -q 'second-batch' $O/o16.out && grep -q '^ALARM r16' $O/o16.out; check $? 0 "…with both lines and the ALARM"
# a stream past its deadline ends with the ALARM even while lines keep coming
( armed $O/o17.out; for i in $(seq 1 24); do $B/jlog --tag builder "DONE busy-$i" >/dev/null; sleep 0.5; done ) & bp=$!
t0=$(date +%s)
HUB_TAG=hub-16 bounded 30 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --stream --settle 1 --for 4s --note r17 --caller s17 > $O/o17.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 )); wait $bp
check "$rc:$(grep -c '^ALARM r17' $O/o17.out)" "3:1" "--stream ends at the deadline under a steady stream of lines"
[ $el -le 9 ]; check $? 0 "…within a settle of it (${el}s)"
# a repeated `hub` tag (a hub registered with the tag `hub` itself) still holds
( armed $O/o18.out; $B/jlog --tag stage-b-hub-3 "@hub FYI repeated tag" >/dev/null ) &
$B/jwait --journal --stage stage-a --tag hub --tag hub --hub-events --settle 1 --for 4s --note r18 --caller s18 > $O/o18.out 2>&1; rc=$?
check $rc 3 "a repeated --tag hub: another hub's plain line is still held"
# 11. NEXT WAIT: an idle stage gets one long background wait (inside the Bash cap), a busy one a Monitor stream;
# a held line wakes a long wait after HELD_MAX at the latest; a Codex host gets no hint
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --stream --settle 0 --for 2s --note r19 --caller s19 > $O/o19.out 2>&1
grep -q "^NEXT WAIT: nothing runs in stage-a — no Monitor; ONE Bash run_in_background: true, timeout 7200000: jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 0 --note r19 --caller s19 --for 115m$" $O/o19.out
check $? 0 "idle: NEXT WAIT is one background wait inside the 2h Bash cap, without --stream"
BASH_MAX_TIMEOUT_MS=43200000 HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --stream --settle 0 --for 2s --caller s19 > $O/o20.out 2>&1
grep -q "timeout 29100000: jwait .* --for 480m$" $O/o20.out; check $? 0 "idle: a raised BASH_MAX_TIMEOUT_MS gives the full 8h"
AGENT_HUB_ENGINE=codex HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --settle 0 --for 2s --caller s19 > $O/o21.out 2>&1
! grep -q "NEXT WAIT" $O/o21.out; check $? 0 "a Codex host gets no NEXT WAIT"
TOK=busy-token-$$; mkdir -p $O/stage-a/agents/busy1; bash -c "exec -a sleeper-$TOK sleep 60" & sp=$!
printf '{"pid": %s, "session_id": "%s"}\n' $sp $TOK > $O/stage-a/agents/busy1/meta.json
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --settle 0 --for 2s --caller s19 > $O/o22.out 2>&1
kill $sp 2>/dev/null; wait $sp 2>/dev/null; rm -rf $O/stage-a/agents/busy1
grep -q "^NEXT WAIT: running in stage-a: agent busy1 — one Monitor, timeout_ms 1800000: jwait .* --stream$" $O/o22.out
check $? 0 "busy: a live agent of the stage gets a Monitor stream"
bash -c "exec -a 'python3 /x/await --stage stage-a --label ci-mr-7 --log $O/stage-a/coordinator/work/await/x.log --wait --' sleep 60" & ap=$!
bash -c "exec -a 'python3 /x/await --stage stage-a --label other --log /elsewhere/stage-a/coordinator/work/await/x.log --wait --' sleep 60" & ap2=$!
HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --settle 0 --for 2s --caller s19 > $O/o22b.out 2>&1
kill $ap $ap2 2>/dev/null; wait $ap $ap2 2>/dev/null
grep -q "^NEXT WAIT: running in stage-a: await ci-mr-7 — one Monitor" $O/o22b.out && ! grep -q "other" $O/o22b.out
check $? 0 "busy: an await supervisor of this home's stage (not one of another home) gets a Monitor stream"
( armed $O/o23.out; $B/jlog --tag stage-b-hub-3 "@hub FYI held max" >/dev/null ) &
t0=$(date +%s)
JWAIT_HELD_MAX_S=3 HUB_TAG=hub-16 $B/jwait --journal --stage stage-a --tag hub-16 --tag hub --hub-events --settle 0 --for 60s --caller s19 > $O/o23.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check "$rc:$(grep -c 'FYI held max' $O/o23.out)" "0:1" "a held line wakes a long wait after HELD_MAX"
[ $el -le 20 ]; check $? 0 "…long before the deadline (${el}s)"
check "$(waited 29 AGENT_HUB_JWAIT_FOR=50m -- --journal --caller d1 --stage stage-a --stream)" ok "--stream without --for waits 29 minutes, not the setting"
exit $fail
