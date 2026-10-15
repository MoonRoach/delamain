# Sourced first by every tests/t_*.sh (lib.sh does it for the scripts that use lib.sh): no test, however it is started,
# may read or write the machine's real HOME, its hub homes or the registry of homes (${XDG_CONFIG_HOME:-~/.config}/delamain/
# homes.json: every `roles set` / `hub start` / `agent spawn` in a test would add a throw-away home to it, and a later write
# would drop the real entries that do not exist). run_all.sh gives each script a sandbox and sets DELAMAIN_TEST_SANDBOX;
# started alone, the script gets one here. Either way every AGENT_HUB_* / AGENT_TOP_* setting inherited from the caller is
# dropped (AGENT_HUB_STATE_DIR, AGENT_HUB_LOCK_RULES, AGENT_HUB_SCOPE_DIRS… point at real directories the tools would write
# to, and a script that needs one sets it itself after this line), as are the other variables that name a real directory
# or file. tests/t_test_isolation.sh checks that every script sources this and probes both cases.
for _v in $(env | cut -d= -f1 | grep -E '^(AGENT_HUB_|AGENT_TOP_)'); do
  [ "$_v" = AGENT_HUB_HOME ] || unset "$_v"
done
unset _v AGENT_BOARD_FILE CLAUDE_CONFIG_DIR CLAUDE_SESSIONS_DIR CODEX_HOME
# TMPDIR first of all: an inherited one may lie inside the real home or hub, and mktemp would put the test's directories
# there. The standalone sandbox itself is made under /tmp, not under what was inherited.
if [ -z "${DELAMAIN_TEST_SANDBOX:-}" ]; then
  DELAMAIN_TEST_SANDBOX="$(TMPDIR=/tmp mktemp -d)"
  export DELAMAIN_TEST_SANDBOX HOME="$DELAMAIN_TEST_SANDBOX/home" XDG_CONFIG_HOME="$DELAMAIN_TEST_SANDBOX/home/.config"
  export AGENT_HUB_HOME="$HOME/hub-home"   # as run_all.sh sets it: inside the sandbox, never the caller's
  mkdir -p "$HOME"
fi
export TMPDIR="$DELAMAIN_TEST_SANDBOX/tmp"
mkdir -p "$TMPDIR"
