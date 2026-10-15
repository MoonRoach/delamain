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
exit $fail
