#!/bin/bash
# Codex tell: exact public steer/start, bounded unknowns and explicit pending native handoff.
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_BIN=$T/fake_tell_proxy.py TELL_PROXY_LOG=$AGENT_HUB_HOME/proxy.log
python3 "$T/tell_codex.py" "$B" "$AGENT_HUB_HOME"
check $? 0 'Codex immediate tell protocol and native handoff controls'
exit $fail
