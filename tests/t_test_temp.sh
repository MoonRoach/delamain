#!/bin/bash
# Standalone lib users clean all mktemp allocations, including on failure.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
python3 - "$T" <<'PY'
import os, subprocess, sys, tempfile
from pathlib import Path
lib = str(Path(sys.argv[1]) / 'lib.sh')
with tempfile.TemporaryDirectory() as outer:
    for status, custom in ((0, False), (7, False), (0, True), (7, True)):
        result = subprocess.run(['bash', '-c', '''
. "$1"
if [ "$3" = True ]; then
  trap 'printf cleaned > "$4/marker"; test_cleanup' EXIT
fi
printf '%s\n' "$CODEX_HOME"
new_home
printf '%s\n' "$AGENT_HUB_HOME"
mkdir -p "$AGENT_HUB_HOME/fixture"
mktemp -d
exit "$2"
''', 'test-temp', lib, str(status), str(custom), outer], env={**os.environ, 'TMPDIR': outer}, capture_output=True, text=True)
        assert result.returncode == status, result.returncode
        paths = [Path(p) for p in result.stdout.splitlines()]
        leaked = [p for p in paths if p.exists()]
        import shutil
        for p in leaked:
            shutil.rmtree(p)
        assert not leaked, f'standalone test left {len(leaked)} temporary directories'
        marker = Path(outer) / 'marker'
        assert marker.exists() == custom, 'custom EXIT trap must still run'
        marker.unlink(missing_ok=True)
        assert list(Path(outer).iterdir()) == []
print('PASS standalone temporary directories removed on success and failure; exit status preserved')
PY
