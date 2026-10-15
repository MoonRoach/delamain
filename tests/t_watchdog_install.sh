#!/bin/bash
# watchdog install | uninstall | status | notify-test, and `run` while the setting is off: against a fake launchctl,
# crontab, osascript and notify-send on PATH (they log their argv; the fake crontab keeps its text in a file), a
# throw-away HOME and throw-away hub homes. Nothing here touches the real LaunchAgents, crontab or notifications.
# Always `--scheduler launchd|cron` explicitly: the default follows sys.platform and CI runs both Linux and macOS.
. "$(dirname "$0")/lib.sh"
export HOME="$(mktemp -d)"      # a direct `bash tests/t_watchdog_install.sh` must not see the real ~/Library/LaunchAgents
unset AGENT_HUB_WATCHDOG AGENT_HUB_WATCHDOG_EVERY AGENT_HUB_WATCHDOG_WAKE_AFTER AGENT_HUB_WATCHDOG_BACKOFF_MAX \
      AGENT_HUB_WATCHDOG_NIGHT_QUEUE AGENT_HUB_WATCHDOG_API_ERROR AGENT_HUB_NOTIFY_LOCAL AGENT_HUB_NOTIFY_CMD \
      AGENT_HUB_STATE_DIR AGENT_HUB_WATCHDOG_NOW
P=$(mktemp -d); export FAKE_DIR=$P/fake; mkdir -p "$FAKE_DIR"
O=$P/out.txt
UID_=$(id -u)
BINREAL=$(cd "$B" && pwd -P)
PY=$(python3 -c 'import sys; print(sys.executable)')

# ---- the fakes: first on PATH, each logs what it was asked
cat > "$FAKE_DIR/launchctl" <<'SH'
#!/bin/sh
# stateful: bootstrap loads <plist name>, bootout unloads <label>, print succeeds while it is loaded
echo "$*" >> "$FAKE_DIR/launchctl.log"
key() { b=${1##*/}; echo "${b%.plist}"; }
case "$1" in
  bootout) if [ -e "$FAKE_DIR/loaded.$(key "$2")" ]; then rm -f "$FAKE_DIR/loaded.$(key "$2")"; exit 0; fi
           echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  bootstrap) if [ "${FAKE_LAUNCHCTL_FAIL:-}" = bootstrap ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
             : > "$FAKE_DIR/loaded.$(key "$3")"; exit 0 ;;
  print) [ -e "$FAKE_DIR/loaded.$(key "$2")" ] && exit 0; echo "Could not find service" >&2; exit 113 ;;
esac
exit 0
SH
cat > "$FAKE_DIR/crontab" <<'SH'
#!/bin/sh
# -l prints the file (exit 1 "no crontab for x" while it is empty); - replaces it from stdin
echo "$*" >> "$FAKE_DIR/crontab.log"
case "$1" in
  -l) if [ "${FAKE_CRONTAB_FAIL:-}" = read ]; then echo "crontab: cannot read the spool: Permission denied" >&2; exit 1; fi
      if [ -s "$FAKE_DIR/crontab.txt" ]; then cat "$FAKE_DIR/crontab.txt"; exit 0; fi
      echo "crontab: no crontab for $(id -un)" >&2; exit 1 ;;
  -) cat > "$FAKE_DIR/crontab.txt"; cat "$FAKE_DIR/crontab.txt" >> "$FAKE_DIR/crontab-stdin.log"; exit 0 ;;
esac
exit 2
SH
for n in osascript notify-send; do
  printf '#!/bin/sh\necho "%s: $*" >> "$FAKE_DIR/local.log"\nexit ${FAKE_LOCAL_RC:-0}\n' "$n" > "$FAKE_DIR/$n"
done
printf '#!/bin/sh\nprintf "%%s\\n" "--call--" "$@" >> "$FAKE_DIR/remote.log"\nexit ${FAKE_REMOTE_RC:-0}\n' > "$FAKE_DIR/remote.sh"
chmod +x "$FAKE_DIR"/*
export PATH="$FAKE_DIR:$PATH"
CT=$FAKE_DIR/crontab.txt
reset_fakes(){ rm -f "$FAKE_DIR"/*.log "$FAKE_DIR"/loaded.* "$CT"; }

# ---- helpers (JSON or plain text out of python, so the checks read the same on Linux and macOS)
wd(){ "$B/watchdog" "$@" > "$O" 2>&1; RC=$?; }
has(){ grep -q -- "$1" "$O"; }
plget(){ python3 -c 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],"rb")).get(sys.argv[2])))' "$1" "$2" 2>/dev/null; }
cfget(){ python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' "$1" "$2" 2>/dev/null; }
cfset(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(d, open(sys.argv[1],"w"))' "$1" "$2" "$3"; }
mode_of(){ python3 -c 'import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$1" 2>/dev/null; }
shenv(){ python3 - "$1" "$2" <<'PY'
import shlex, sys
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if line.startswith("export " + sys.argv[2] + "="):
        print(shlex.split(line)[1].split("=", 1)[1]); break
PY
}
shexec(){ python3 - "$1" <<'PY'
import json, shlex, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
print(json.dumps(shlex.split(lines[-1])[1:]) if lines and lines[-1].startswith("exec ") else "null")
PY
}
set_tick(){ python3 -c 'import json,sys; json.dump({"stages": {}, "last_tick": sys.argv[2]}, open(sys.argv[1],"w"))' "$1" "$2"; }
count(){ grep -c -- "$1" "$2" 2>/dev/null; }
LD=$HOME/Library/LaunchAgents
nplists(){ ls "$LD" 2>/dev/null | grep -c '\.plist$'; }

# ================================================================ launchd install
reset_fakes
new_home; A=$AGENT_HUB_HOME; SHIM=$A/.state/watchdog/run.sh
printf '{"AGENT_HUB_DEFAULT_EFFORT": "low"}\n' > $A/config.json
CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py wd install --scheduler launchd; check $RC 0 "launchd install exits 0"
has 'watchdog installed: launchd job io.agent-hub.watchdog.'; check $? 0 "…and says what it installed"
PL=$(ls $LD/io.agent-hub.watchdog.*.plist 2>/dev/null | head -1); LABEL=$(basename "$PL" .plist)
echo "$LABEL" | grep -Eq '^io\.agent-hub\.watchdog\.[0-9a-f]{8}$'; check $? 0 "the plist is under ~/Library/LaunchAgents, named io.agent-hub.watchdog.<8 hex>"
check "$(nplists)" 1 "exactly one plist"
check "$(plget $PL Label)" "\"$LABEL\"" "plist Label is the file's label"
check "$(plget $PL StartInterval)" 300 "plist StartInterval is 300 (5 min by default)"
check "$(plget $PL RunAtLoad)" false "plist RunAtLoad is false"
check "$(plget $PL ProgramArguments)" "[\"$SHIM\"]" "plist ProgramArguments is the shim only"
check "$(mode_of $SHIM)" 700 "the shim is mode 700 (it may carry the notification address)"
check "$(shenv $SHIM AGENT_HUB_HOME)" "$A" "shim exports AGENT_HUB_HOME (the throw-away home)"
check "$(shenv $SHIM PATH)" "$PATH" "shim exports the installing PATH"
check "$(shenv $SHIM CLAUDE_BIN)" "$T/fake_claude.py" "shim exports CLAUDE_BIN set at install time"
check "$(shenv $SHIM CODEX_BIN)" "$T/fake_codex.py" "shim exports CODEX_BIN set at install time"
grep -qx "# bin: $BINREAL" $SHIM; check $? 0 "shim records \`# bin: <the bin under test>\`"
check "$(shexec $SHIM)" "[\"$PY\", \"$BINREAL/watchdog\", \"run\"]" "shim ends in \`exec <python> <bin>/watchdog run\`"
check "$(cat $FAKE_DIR/launchctl.log 2>/dev/null)" "bootout gui/$UID_/$LABEL
bootstrap gui/$UID_ $PL" "launchctl: bootout of the label, then bootstrap gui/<uid> <plist>"
check "$(cfget $A/config.json AGENT_HUB_WATCHDOG)" true "config.json of the hub home: AGENT_HUB_WATCHDOG true"
check "$(cfget $A/config.json AGENT_HUB_DEFAULT_EFFORT)" '"low"' "…and its other key is kept"
# negative: bootstrap fails
new_home; FH=$AGENT_HUB_HOME; FAKE_LAUNCHCTL_FAIL=bootstrap wd install --scheduler launchd; check $RC 1 "negative: a launchctl that fails bootstrap: install exits 1"
has 'launchctl bootstrap failed'; check $? 0 "…and says so"
AGENT_HUB_HOME=$FH wd uninstall --scheduler launchd   # the failed install leaves its plist behind: clean up
AGENT_HUB_HOME=$A

# ---- status (launchd)
wd status --scheduler launchd; check $RC 0 "status exits 0"
has '^job: installed (launchd io.agent-hub.watchdog\.[0-9a-f]*); setting AGENT_HUB_WATCHDOG on; interval 5 min'; check $? 0 "status after install: installed, setting on, interval 5 min"
has '^last tick: never'; check $? 0 "status before a tick: last tick: never"
has 'install again'; check $? 1 "negative: the shim points at this bin, no 'install again'"
has '^notifications: local on; remote none'; check $? 0 "status: notification channels (local on, remote none)"
AGENT_HUB_NOTIFY_LOCAL=off AGENT_HUB_NOTIFY_CMD='["x","{message}"]' wd status --scheduler launchd
has '^notifications: local off; remote AGENT_HUB_NOTIFY_CMD (2 args)'; check $? 0 "…with local off and a remote command: both shown"
# a tick: the setting is on (install turned it on); no stages, no claude involved
wd run; check $RC 0 "run with the setting on and no stages exits 0"
[ -f $A/.state/watchdog/state.json ]; check $? 0 "…and writes .state/watchdog/state.json"
wd status --scheduler launchd; has '^last tick: 20[0-9-]* [0-9:]* ([0-9a-z ]* ago)$'; check $? 0 "status after a tick: last tick shows the time"
has 'late'; check $? 1 "negative: a fresh tick is not late"
set_tick $A/.state/watchdog/state.json "$(utc_iso -10)"
wd status --scheduler launchd; has 'late'; check $? 1 "negative: a tick 10 min old (< 3 x 5 min) is not late"
set_tick $A/.state/watchdog/state.json "$(utc_iso -120)"
wd status --scheduler launchd; has '^last tick: .* — late: the job may not be running'; check $? 0 "a tick 2 h old (> 3 x 5 min) is late"
cp $SHIM $P/shim.good; subst $SHIM '^# bin: .*' "# bin: $P/other-bin"
wd status --scheduler launchd; has "job runs the plugin at $P/other-bin, this tool is .*: install again"; check $? 0 "a shim that records another bin: 'install again'"

# ---- second install: same files, same label, one bootstrap per call; the interval follows config.json
: > $FAKE_DIR/launchctl.log
cfset $A/config.json AGENT_HUB_WATCHDOG_EVERY '"10m"'
CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py wd install --scheduler launchd; check $RC 0 "second install exits 0"
check "$(nplists)" 1 "still one plist"
check "$(ls $LD/io.agent-hub.watchdog.*.plist | head -1)" "$PL" "the label is unchanged"
check "$(plget $PL StartInterval)" 600 "AGENT_HUB_WATCHDOG_EVERY=10m in the home's config.json: StartInterval 600"
grep -qx "# bin: $BINREAL" $SHIM; check $? 0 "the shim was rewritten (its bin line is current again)"
check "$(count '^bootstrap' $FAKE_DIR/launchctl.log)" 1 "one bootstrap for the second install call"
cp $PL $P/plist.2
CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py wd install --scheduler launchd
cmp -s $PL $P/plist.2; check $? 0 "a third install with the same settings leaves the plist byte-identical"
check "$(count '^bootstrap' $FAKE_DIR/launchctl.log)" 2 "…and again exactly one bootstrap per install call"

# ---- CLAUDE_CONFIG_DIR: ~/.claude is not neutral (the CLI then reads ~/.claude/.claude.json, not ~/.claude.json)
CLAUDE_CONFIG_DIR=$HOME/.claude CLAUDE_BIN=$T/fake_claude.py wd install --scheduler launchd
check "$(shenv $SHIM CLAUDE_CONFIG_DIR)" "$HOME/.claude" "negative: ~/.claude without ~/.claude.json (it may hold the real config) is exported"
echo '{}' > $HOME/.claude.json
CLAUDE_CONFIG_DIR=$HOME/.claude CLAUDE_BIN=$T/fake_claude.py wd install --scheduler launchd; check $RC 0 "install from a shell with CLAUDE_CONFIG_DIR=~/.claude and a ~/.claude.json exits 0"
grep -q '^export CLAUDE_CONFIG_DIR=' $SHIM; check $? 1 "…and the shim does not export it"
grep -qx 'unset CLAUDE_CONFIG_DIR' $SHIM; check $? 0 "…it unsets it (nor inherited from launchd/cron)"
check "$(shexec $SHIM)" "[\"$PY\", \"$BINREAL/watchdog\", \"run\"]" "…and still ends in the exec line"
CLAUDE_CONFIG_DIR=$HOME/.claude/ CLAUDE_BIN=$T/fake_claude.py wd install --scheduler launchd
grep -q '^export CLAUDE_CONFIG_DIR=' $SHIM; check $? 1 "…nor with a trailing slash"
check "$(CLAUDE_CONFIG_DIR=$HOME/.claude python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.child_env().get("CLAUDE_CONFIG_DIR", "unset"))' "$B")" unset "child_env (agent spawn, watchdog run) drops it too"
mkdir -p $P/cc; CLAUDE_CONFIG_DIR=$P/cc CLAUDE_BIN=$T/fake_claude.py wd install --scheduler launchd
check "$(shenv $SHIM CLAUDE_CONFIG_DIR)" "$P/cc" "negative: another CLAUDE_CONFIG_DIR is exported as set"
grep -q '^unset CLAUDE_CONFIG_DIR' $SHIM; check $? 1 "…and not unset"
check "$(CLAUDE_CONFIG_DIR=$P/cc python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.child_env().get("CLAUDE_CONFIG_DIR", "unset"))' "$B")" "$P/cc" "negative: child_env keeps another config dir"
wd status --scheduler launchd; has 'job sets CLAUDE_CONFIG_DIR'; check $? 1 "negative: status does not flag another config dir"
subst $SHIM '^export CLAUDE_CONFIG_DIR=.*' "export CLAUDE_CONFIG_DIR=$HOME/.claude"
wd status --scheduler launchd; has "job sets CLAUDE_CONFIG_DIR=$HOME/.claude: .*Workspace not trusted.*install again"; check $? 0 "a shim written before the fix (CLAUDE_CONFIG_DIR=~/.claude): status says install again"
subst $SHIM '^export CLAUDE_CONFIG_DIR=.*' "export CLAUDE_CONFIG_DIR='/a"
wd status --scheduler launchd; check $RC 0 "negative: a shim line status cannot parse (an unclosed quote) does not crash status"
rm -f $HOME/.claude.json
CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py wd install --scheduler launchd   # back to the shim the cron part expects
check "$(cfget $A/config.json AGENT_HUB_WATCHDOG_EVERY)" '"10m"' "install keeps the home's other keys (EVERY)"
# another home: another label
new_home; B2=$AGENT_HUB_HOME; wd install --scheduler launchd; check $RC 0 "install of another home exits 0"
check "$(nplists)" 2 "another home: its own plist"
PL2=$(ls $LD/io.agent-hub.watchdog.*.plist | grep -v "$LABEL" | head -1)
[ -n "$PL2" ] && [ "$PL2" != "$PL" ]; check $? 0 "a different label for another home"
check "$(plget $PL2 StartInterval)" 300 "…with its own interval (300)"
AGENT_HUB_HOME=$B2 wd uninstall --scheduler launchd
AGENT_HUB_HOME=$A

# ---- status: plist present but the job not loaded is not "installed"
rm -f $FAKE_DIR/loaded.$LABEL
wd status --scheduler launchd; has '^job: not installed'; check $? 0 "a plist whose job launchctl does not know: not installed"

# ---- uninstall (launchd)
: > $FAKE_DIR/launchctl.log
wd uninstall --scheduler launchd; check $RC 0 "launchd uninstall exits 0"
has '^watchdog uninstalled'; check $? 0 "…and says so"
grep -qx "bootout gui/$UID_/$LABEL" $FAKE_DIR/launchctl.log; check $? 0 "launchctl bootout gui/<uid>/<label> called"
[ -e $PL ]; check $? 1 "plist removed"
[ -e $SHIM ]; check $? 1 "shim removed"
check "$(cfget $A/config.json AGENT_HUB_WATCHDOG)" false "config.json: AGENT_HUB_WATCHDOG false"
check "$(cfget $A/config.json AGENT_HUB_DEFAULT_EFFORT)" '"low"' "…and the other keys are kept"
wd uninstall --scheduler launchd; check $RC 0 "a second uninstall exits 0"
wd status --scheduler launchd; has '^job: not installed — `watchdog install`; setting AGENT_HUB_WATCHDOG off'; check $? 0 "status after uninstall: not installed, setting off"

# ================================================================ cron install
reset_fakes
FOREIGN='# nightly backup
0 3 * * * /usr/bin/backup --all
@reboot /usr/local/bin/boot-hook'
new_home; CA=$AGENT_HUB_HOME; SHA=$CA/.state/watchdog/run.sh
printf '{"AGENT_HUB_DEFAULT_EFFORT": "low"}\n' > $CA/config.json
printf '%s\n' "$FOREIGN" > $CT
wd status --scheduler cron; has '^job: not installed'; check $? 0 "cron status before install: no own line"
LA="*/5 * * * * $SHA  # agent-hub-watchdog $CA"
wd install --scheduler cron; check $RC 0 "cron install exits 0"
check "$(cat $CT)" "$FOREIGN
$LA" "the crontab: foreign lines untouched and in order, then exactly one own line with the marker"
check "$(cat $CT | grep -c 'agent-hub-watchdog')" 1 "…one marked line"
check "$(mode_of $SHA)" 700 "the shim is mode 700"
check "$(cfget $CA/config.json AGENT_HUB_WATCHDOG)" true "config.json: AGENT_HUB_WATCHDOG true"
check "$(cfget $CA/config.json AGENT_HUB_DEFAULT_EFFORT)" '"low"' "…its other key kept"
wd install --scheduler cron; check $RC 0 "second cron install exits 0"
check "$(cat $CT)" "$FOREIGN
$LA" "a second install does not duplicate the line"
wd status --scheduler cron; has '^job: installed (cron); setting AGENT_HUB_WATCHDOG on; interval 5 min'; check $? 0 "cron status after install: installed"
has 'install again'; check $? 1 "negative: shim current, no 'install again'"
cp $SHA $P/shim.cron; subst $SHA '^# bin: .*' "# bin: $P/other-bin"
wd status --scheduler cron; has 'install again'; check $? 0 "cron status: an edited bin line gives 'install again'"
cp $P/shim.cron $SHA
# another home next to the first
new_home; CB=$AGENT_HUB_HOME; SHB=$CB/.state/watchdog/run.sh
LB="*/5 * * * * $SHB  # agent-hub-watchdog $CB"
wd install --scheduler cron; check $RC 0 "cron install for another home exits 0"
check "$(cat $CT)" "$FOREIGN
$LA
$LB" "another home adds its own line next to the first (two lines, two homes)"
new_home; CC=$AGENT_HUB_HOME
wd status --scheduler cron; has '^job: not installed'; check $? 0 "negative: a third home sees no line of its own although two others exist"
# uninstall removes only its own line
AGENT_HUB_HOME=$CA wd uninstall --scheduler cron; check $RC 0 "cron uninstall of one home exits 0"
check "$(cat $CT)" "$FOREIGN
$LB" "uninstall removes only its own line: foreign lines and the other home's line stay"
[ -e $SHA ]; check $? 1 "…and its shim"
check "$(cfget $CA/config.json AGENT_HUB_WATCHDOG)" false "…and the setting goes off"
AGENT_HUB_HOME=$CA wd uninstall --scheduler cron; check $RC 0 "a second cron uninstall exits 0"
check "$(cat $CT)" "$FOREIGN
$LB" "…and changes nothing"
AGENT_HUB_HOME=$CB wd uninstall --scheduler cron
check "$(cat $CT)" "$FOREIGN" "the last uninstall leaves the foreign lines alone"
# intervals
new_home; CD=$AGENT_HUB_HOME; SHD=$CD/.state/watchdog/run.sh
AGENT_HUB_WATCHDOG_EVERY=2h wd install --scheduler cron; check $RC 0 "EVERY=2h install exits 0"
check "$(grep 'agent-hub-watchdog' $CT)" "0 */2 * * * $SHD  # agent-hub-watchdog $CD" "EVERY=2h gives \`0 */2 * * *\`"
before=$(cat $CT)
AGENT_HUB_WATCHDOG_EVERY=90m wd install --scheduler cron; check $RC 2 "negative: EVERY=90m with cron exits 2"
has 'cron runs the job every 1-59 minutes or a whole number of hours'; check $? 0 "…with the cron message"
check "$(cat $CT)" "$before" "…and the crontab is unchanged"
AGENT_HUB_HOME=$CD wd uninstall --scheduler cron
# an empty crontab to begin with (crontab -l exits 1), and back to empty
: > $CT
new_home; CE=$AGENT_HUB_HOME
wd install --scheduler cron; check $RC 0 "install into an empty crontab exits 0"
check "$(grep -c . $CT)" 1 "…exactly one line"
has 'no crontab'; check $? 1 "…and the fake's 'no crontab' message did not leak out"
wd uninstall --scheduler cron; check $RC 0 "uninstall of the only line exits 0"
[ -s $CT ]; check $? 1 "…the crontab is empty again"
# a crontab that cannot be read is not an empty crontab: install and uninstall leave it alone (exit 1 without "no crontab")
reset_fakes
printf '%s\n' "$FOREIGN" > $CT
new_home; CF=$AGENT_HUB_HOME
FAKE_CRONTAB_FAIL=read wd install --scheduler cron; check $RC 1 "negative: install with an unreadable crontab exits 1"
has 'crontab -l failed'; check $? 0 "…and says crontab -l failed"
check "$(cat $CT)" "$FOREIGN" "…the crontab is untouched (the foreign lines are not replaced by the own line)"
grep -q '^-$' $FAKE_DIR/crontab.log; check $? 1 "…and crontab - was never called"
wd install --scheduler cron; check $RC 0 "control: the same install with a readable crontab exits 0"
FAKE_CRONTAB_FAIL=read wd uninstall --scheduler cron; check $RC 1 "negative: uninstall with an unreadable crontab exits 1"
check "$(grep -c 'agent-hub-watchdog' $CT)" 1 "…the own line is still there and the foreign lines too ($(grep -c . $CT) lines)"
check "$(grep -c . $CT)" 4 "…nothing was dropped"
wd uninstall --scheduler cron; check $RC 0 "control: uninstall with a readable crontab exits 0"
check "$(cat $CT)" "$FOREIGN" "…only the own line went"

# a % in the hub home: cron would cut the command at it, so it is written as \%, and the line is still found as the home's own
reset_fakes
PH=$P/h%d; mkdir -p "$PH"; export AGENT_HUB_HOME=$PH
wd install --scheduler cron; check $RC 0 "install for a home with % in its path exits 0"
grep -q '[^\\]%' $CT; check $? 1 "negative: no unescaped % in the crontab line"
grep -q 'h\\%d' $CT; check $? 0 "…the % is written as \\%"
wd install --scheduler cron; check "$(grep -c 'agent-hub-watchdog' $CT)" 1 "…a second install replaces the line (still found as own)"
wd status --scheduler cron; has '^job: installed (cron)'; check $? 0 "…status finds it"
wd uninstall --scheduler cron; check "$(grep -c . $CT)" 0 "…and uninstall removes it"

# ================================================================ notify-test
reset_fakes
new_home
wd notify-test; check $RC 0 "notify-test with a local notifier exits 0"
check "$(count 'delamain: test notification' $FAKE_DIR/local.log)" 1 "osascript or notify-send called once with 'delamain: test notification'"
[ -e $FAKE_DIR/remote.log ]; check $? 1 "negative: no remote command configured, none called"
has '^local: ok'; check $? 0 "…and the output names the channel"
rm -f $FAKE_DIR/local.log
AGENT_HUB_NOTIFY_CMD="[\"$FAKE_DIR/remote.sh\",\"--data\",\"{message}\"]" wd notify-test; check $RC 0 "notify-test with a remote command exits 0"
check "$(count 'delamain: test notification' $FAKE_DIR/local.log)" 1 "…the local notifier was called once"
check "$(cat $FAKE_DIR/remote.log)" "--call--
--data
delamain: test notification" "…the remote got the substituted message as one argument"
grep -q '{message}' $FAKE_DIR/remote.log; check $? 1 "…no {message} literal left"
has '^remote: ok'; check $? 0 "…and the output says remote ok"
: > $FAKE_DIR/remote.log; rm -f $FAKE_DIR/local.log
AGENT_HUB_NOTIFY_LOCAL=off AGENT_HUB_NOTIFY_CMD="[\"$FAKE_DIR/remote.sh\",\"{message}\"]" wd notify-test; check $RC 0 "remote only (local off) exits 0"
[ -e $FAKE_DIR/local.log ]; check $? 1 "negative: local off, the local notifier is not called"
check "$(count '^delamain: test notification$' $FAKE_DIR/remote.log)" 1 "…the remote is"
AGENT_HUB_NOTIFY_LOCAL=off wd notify-test; check $RC 1 "negative: local off and no remote: exit 1"
has 'no channel'; check $? 0 "…says there is no channel"
FAKE_REMOTE_RC=3 AGENT_HUB_NOTIFY_LOCAL=off AGENT_HUB_NOTIFY_CMD="[\"$FAKE_DIR/remote.sh\",\"{message}\"]" wd notify-test; check $RC 1 "negative: a remote that exits non-zero: exit 1"
has 'FAILED'; check $? 0 "…says FAILED"
FAKE_REMOTE_RC=3 AGENT_HUB_NOTIFY_CMD="[\"$FAKE_DIR/remote.sh\",\"{message}\"]" wd notify-test; check $RC 1 "…also with a healthy local channel next to it"
has '^local: ok' && has '^remote: FAILED'; check $? 0 "…each channel reports on its own line"

# ================================================================ run while the setting is off
reset_fakes
new_home; W=$AGENT_HUB_HOME
wd run; check $RC 0 "run with AGENT_HUB_WATCHDOG unset exits 0"
has 'watchdog is off'; check $? 0 "…and says the watchdog is off"
[ -e $W/.state/watchdog/state.json ]; check $? 1 "…and does not create .state/watchdog/state.json"
wd run --dry-run; check $RC 0 "run --dry-run with the setting off exits 0"
has '^\[plan\]'; check $? 0 "…it still runs (prints [plan] lines)"
has 'watchdog is off'; check $? 1 "…and does not say it is off"
[ -e $W/.state/watchdog/state.json ]; check $? 1 "…and writes no state"
printf '{"AGENT_HUB_WATCHDOG": true}\n' > $W/config.json
AGENT_HUB_WATCHDOG=off wd run; has 'watchdog is off'; check $? 0 "the environment's off wins over config.json's true"
[ -e $W/.state/watchdog/state.json ]; check $? 1 "…no state"
wd run; check $RC 0 "control: the setting on in config.json runs a tick"
[ -f $W/.state/watchdog/state.json ]; check $? 0 "…and writes the state"
exit $fail
