#!/bin/bash
# The newest Claude event can precede large tool results; reads remain bounded.
. "$(dirname "$0")/lib.sh"
new_home
python3 - "$B" "$AGENT_HUB_HOME" <<'PY'
import io, json, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import limit_pace as lp
root = Path(sys.argv[2])
log = root / 'stage-a/agents/only/log.jsonl'
log.parent.mkdir(parents=True)
def event(used):
    return (json.dumps({'type': 'rate_limit_event', 'rate_limit_info': {'unifiedWindows': {
        'seven_day': {'utilization': used, 'resetsAt': 9999999999}}}}) + '\n').encode()
old, newest = event(.21), event(.42)
tail = (b'{"tool_result":"' + b'x' * 90000 + b'"}\n') * 8
log.write_bytes(old + newest + tail)
assert lp.claude_samples(root)['7d'][0].used == 42, 'sole agent: event beyond 256 KB still supplies a reading'
# Move the event across every possible split position inside its JSON line.
for offset in range(len(newest) + 1):
    log.write_bytes(old + newest + b'x' * (lp.TAIL_BYTES - offset) + b'\n')
    assert lp._claude_file(log)[0][1] == 42, f'chunk boundary {offset}'
# Truncated and malformed events do not hide the last complete valid event.
log.write_bytes(newest + tail + b'{"type":"rate_limit_event"}\n' + newest[:-1])
assert lp._claude_file(log)[0][1] == 42
# Instrument actual bytes: even a giant line without events must not read past the cap.
cap = lp.CLAUDE_SCAN_BYTES
for data in (b'x' * (cap * 2), b'{}\n' * cap):
    class Meter(io.BytesIO):
        read_bytes = 0
        def read(self, size=-1):
            got = super().read(size)
            self.read_bytes += len(got)
            return got
        def close(self):
            pass
    stream = Meter(data)
    with patch.object(Path, 'open', return_value=stream):
        assert lp._claude_file(log) == []
    assert stream.read_bytes <= cap, stream.read_bytes
print('PASS older Claude event, every chunk boundary, incomplete events, bounded no-event reads')
PY
exit $?
