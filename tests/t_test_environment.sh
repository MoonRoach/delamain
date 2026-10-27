#!/usr/bin/env bash
# Inherited host attribution must not select the real app in stand-in CLI tests.
set -eu
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BINS="$(cd "$TEST_DIR/../bin" && pwd)"
. "$(dirname "$0")/isolate.sh"
unset AGENT_ROLE
export CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop'
export CODEX_APP_TOOLS_PIPE_PATH='/tmp/delamain-test-app-pipe'
PYTHONPATH="$TEST_BINS" python3 -c '
import engines
assert engines.codex_desktop()
print("PASS positive control: inherited app markers select Desktop")
'
. "$TEST_DIR/lib.sh"
PYTHONPATH="$TEST_BINS" python3 -c '
import engines
assert not engines.codex_desktop()
print("PASS shared test helpers isolate the caller Desktop attribution")
'
export CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop'
export CODEX_APP_TOOLS_PIPE_PATH='/tmp/delamain-test-app-pipe'
PYTHONPATH="$TEST_BINS" python3 -c '
import engines
assert engines.codex_desktop()
print("PASS deliberate per-test Desktop fixtures still work")
'
