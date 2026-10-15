# Sourced first by every tests/t_*.sh (lib.sh does it for the scripts that use lib.sh): no test, however it is started,
# may read or write the machine's real HOME, its hub homes or the registry of homes (${XDG_CONFIG_HOME:-~/.config}/delamain/
# homes.json: every `roles set` / `hub start` / `agent spawn` in a test would add a throw-away home to it, and a later write
# would drop the real entries that do not exist). run_all.sh gives each script a sandbox and sets DELAMAIN_TEST_SANDBOX;
# started alone, the script gets one here. tests/t_test_isolation.sh checks that every script sources this.
if [ -z "${DELAMAIN_TEST_SANDBOX:-}" ]; then
  DELAMAIN_TEST_SANDBOX="$(mktemp -d)"
  export DELAMAIN_TEST_SANDBOX HOME="$DELAMAIN_TEST_SANDBOX/home" XDG_CONFIG_HOME="$DELAMAIN_TEST_SANDBOX/home/.config"
  mkdir -p "$HOME"
fi
