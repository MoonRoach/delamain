#!/bin/bash
# No test script, however it is started, may touch the real HOME, the real hub homes or the registry of homes
# (${XDG_CONFIG_HOME:-~/.config}/delamain/homes.json): every tests/t_*.sh sources tests/isolate.sh (directly, or through
# lib.sh), which gives a script started alone a sandbox HOME and XDG_CONFIG_HOME. Controls: a script that does not is caught
# by the same checker; a tool run after isolate.sh registers its home in the sandbox, never in the caller's XDG directory.
. "$(dirname "$0")/isolate.sh"
T="$(cd "$(dirname "$0")" && pwd)"
fail=0
check(){ if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got $1 want $2)"; fail=1; fi; }
unisolated(){ for f in "$@"; do grep -Eq '^\. "\$\(dirname "(\$0|\$\{BASH_SOURCE\[0\]\})"\)/(lib|isolate)\.sh"' "$f" || echo "$f"; done; }
check "$(unisolated "$T"/t_*.sh | tr '\n' ' ')" "" "every test script sources lib.sh or isolate.sh"
S=$(mktemp -d)
printf '#!/bin/bash\nset -u\necho hello\n' > $S/t_bare.sh
check "$(unisolated $S/t_bare.sh)" "$S/t_bare.sh" "control: a script that sources neither is caught"
# a script started alone: its HOME and XDG_CONFIG_HOME are not the caller's, and a registration lands there
REAL=$S/real; mkdir -p $REAL/home $REAL/xdg
cat > $S/t_probe.sh <<EOF2
#!/bin/bash
set -u
. "$T/isolate.sh"
echo "\$HOME|\$XDG_CONFIG_HOME"
AGENT_HUB_HOME=\$HOME/h $T/../bin/roles set hub 11111111-1111-4111-8111-111111111111 --tag hub-1 --stage s1 > /dev/null 2>&1
[ -f "\$XDG_CONFIG_HOME/delamain/homes.json" ] && echo registered
EOF2
out=$(env -u DELAMAIN_TEST_SANDBOX HOME=$REAL/home XDG_CONFIG_HOME=$REAL/xdg bash $S/t_probe.sh)
check "$(echo "$out" | head -1 | grep -c "^$REAL")" 0 "a script started alone gets a HOME and XDG_CONFIG_HOME of its own"
check "$(echo "$out" | tail -1)" registered "…a registration made in it lands in its own XDG directory"
check "$(find $REAL -type f | wc -l | tr -d ' ')" 0 "…and nothing at all reaches the caller's"
# the same probe without isolate.sh writes to the caller's: the control that the checks above can fail
sed -i.bak '/isolate.sh/d' $S/t_probe.sh; rm -f $S/t_probe.sh.bak
env -u DELAMAIN_TEST_SANDBOX HOME=$REAL/home XDG_CONFIG_HOME=$REAL/xdg bash $S/t_probe.sh > /dev/null
[ -f $REAL/xdg/delamain/homes.json ]; check $? 0 "control: without isolate.sh the registration lands in the caller's XDG directory"
# inherited AGENT_HUB_* / AGENT_TOP_* settings that name real directories are dropped, with a sandbox of their own or one
# run_all.sh gave (AGENT_HUB_HOME alone is kept in the second case: it is the sandbox's); a caching agent-top then writes
# nothing at the caller's AGENT_HUB_STATE_DIR
mkdir -p $REAL/h
cat > $S/t_env.sh <<EOF2
#!/bin/bash
set -u
. "$T/isolate.sh"
echo "\${AGENT_HUB_STATE_DIR:-}|\${AGENT_HUB_LOCK_RULES:-}|\${AGENT_HUB_SCOPE_DIRS:-}|\${AGENT_TOP_HUB_BIN:-}|\${AGENT_BOARD_FILE:-}|\${CLAUDE_CONFIG_DIR:-}|\${AGENT_HUB_HOME:-}"
$T/../bin/roles set hub 11111111-1111-4111-8111-111111111111 --tag hub-1 --stage s1 > /dev/null 2>&1
$T/../bin/agent-top --json > /dev/null 2>&1
EOF2
DIRTY="AGENT_HUB_STATE_DIR=$REAL/state AGENT_HUB_LOCK_RULES=$REAL/rules.json AGENT_HUB_SCOPE_DIRS=$REAL/scope AGENT_TOP_HUB_BIN=$REAL/hub AGENT_BOARD_FILE=$REAL/board.md CLAUDE_CONFIG_DIR=$REAL/claude AGENT_HUB_HOME=$REAL/h"
out=$(env -u DELAMAIN_TEST_SANDBOX HOME=$REAL/home XDG_CONFIG_HOME=$REAL/xdg $DIRTY AGENT_TOP_CACHE=1 bash $S/t_env.sh | head -1)
check "$(echo "$out" | grep -c "$REAL")" 0 "a script started alone drops every inherited AGENT_HUB_*/AGENT_TOP_* path and the board, claude config and AGENT_HUB_HOME of the caller"
check "$(find $REAL -type f -newer $S/t_env.sh | wc -l | tr -d ' ')" 0 "…and agent-top and roles write nothing at the caller's state dir, home or config"
SB=$S/sandbox; mkdir -p $SB/home
out=$(env DELAMAIN_TEST_SANDBOX=$SB HOME=$SB/home XDG_CONFIG_HOME=$SB/home/.config $DIRTY AGENT_HUB_HOME=$SB/home/hub-home AGENT_TOP_CACHE=1 bash $S/t_env.sh | head -1)
check "$(echo "$out" | cut -d'|' -f1-6 | grep -c "$REAL")" 0 "a script run by run_all.sh drops them too…"
check "$(echo "$out" | cut -d'|' -f7)" "$SB/home/hub-home" "…and keeps the AGENT_HUB_HOME run_all.sh gave it"
# control: the same probe without isolate.sh keeps the caller's state dir and writes the agent-top cache there
sed -i.bak '/isolate.sh/d' $S/t_env.sh; rm -f $S/t_env.sh.bak
env -u DELAMAIN_TEST_SANDBOX HOME=$REAL/home XDG_CONFIG_HOME=$REAL/xdg $DIRTY AGENT_HUB_HOME=$REAL/h AGENT_TOP_CACHE=1 bash $S/t_env.sh > /dev/null 2>&1
[ -d $REAL/state ]; check $? 0 "control: without isolate.sh the caller's AGENT_HUB_STATE_DIR receives the cache"
# an inherited TMPDIR (it may lie inside the real home or hub) never receives a test's directories: not from a script started
# alone, not from the suite's own bootstrap
mkdir -p $REAL/tmp $S/fakebin
# a bare `mktemp -d` honours TMPDIR on Linux and not on macOS: this stand-in makes it so everywhere
printf '#!/bin/sh\nif [ "$#" = 1 ] && [ "$1" = -d ]; then exec /usr/bin/mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXX"; fi\nexec /usr/bin/mktemp "$@"\n' > $S/fakebin/mktemp; chmod +x $S/fakebin/mktemp
cat > $S/t_tmp.sh <<EOF2
#!/bin/bash
set -u
. "$T/isolate.sh"
d=\$(mktemp -d); case "\$d" in "\$DELAMAIN_TEST_SANDBOX"/*) echo inside;; *) echo "outside \$d";; esac
EOF2
check "$(env -u DELAMAIN_TEST_SANDBOX PATH=$S/fakebin:$PATH HOME=$REAL/home TMPDIR=$REAL/tmp bash $S/t_tmp.sh)" inside "a script started alone makes its temporary directories in its sandbox, not under an inherited TMPDIR"
check "$(env DELAMAIN_TEST_SANDBOX=$SB PATH=$S/fakebin:$PATH HOME=$SB/home TMPDIR=$REAL/tmp bash $S/t_tmp.sh)" inside "…and so does one run by run_all.sh"
# the suite's bootstrap: a copy of run_all.sh over one probe test, with the caller's TMPDIR pointing at a "real" place
mkdir -p $S/suite/tests $S/suite/bin; cp $T/run_all.sh $T/isolate.sh $S/suite/tests/; cp $T/../bin/jlog $T/../bin/hubcore.py $S/suite/bin/
printf '#!/bin/bash\n. "$(dirname "$0")/isolate.sh"\nmktemp -d > /dev/null\necho "PASS probe"\n' > $S/suite/tests/t_probe.sh
(cd $S && env -u DELAMAIN_TEST_SANDBOX PATH=$S/fakebin:$PATH TMPDIR=$REAL/tmp bash $S/suite/tests/run_all.sh $S/out > $S/suite.out 2>&1)
check "$(find $REAL/tmp | wc -l | tr -d ' ')" 1 "the suite's bootstrap (HOME, sandboxes, logs' scratch) allocates nothing under an inherited TMPDIR"
grep -q "^t_probe: exit=0 pass=1" $S/suite.out; check $? 0 "…and still runs its scripts (the probe passed)"
# control: the old bootstrap (mktemp before TMPDIR is replaced) does allocate there
sed 's|^SANDBOX="$(TMPDIR=/tmp mktemp -d)"; mkdir -p "$SANDBOX/tmp"; export TMPDIR="$SANDBOX/tmp"|SANDBOX="$(mktemp -d)"; mkdir -p "$SANDBOX/tmp"|' $T/run_all.sh > $S/suite/tests/run_all.sh
(cd $S && env -u DELAMAIN_TEST_SANDBOX PATH=$S/fakebin:$PATH TMPDIR=$REAL/tmp bash $S/suite/tests/run_all.sh $S/out2 > $S/suite2.out 2>&1)
[ "$(find $REAL/tmp | wc -l | tr -d ' ')" -gt 1 ]; check $? 0 "control: a bootstrap that calls mktemp before replacing TMPDIR allocates in the caller's"
exit $fail
