#!/bin/bash
# The real Bash hook must answer promptly and preserve lock decisions around heredocs.
. "$(dirname "$0")/lib.sh"
new_home
python3 - "$HOOKS" "$AGENT_HUB_HOME" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

hooks, home = map(Path, sys.argv[1:])
record = {"kind": "main-merge", "repo": "*", "session_id": "other", "owner_name": "steward",
          "until": "2099-01-01T00:00:00+00:00", "why": "merge train"}
(home / "board.md").write_text("# board\n\n```locks\n" + json.dumps(record) + "\n```\n")
env = dict(os.environ, AGENT_HUB_HOOK_DEADLINE_S="8.5")
failed = 0
cases = [
    # Exact command from review-104-input-latency.json; no developer-local fixture dependency.
    ("reviewer latency input", "printf '%s' '<<EOF\n" + "\n" * 50000 + "END'", False),
    ("ordinary merge", "gh pr merge 12 --squash", True),
    ("ordinary feature push", "git push origin feature-x", False),
    ("quoted merge", "echo 'gh pr merge 12'", False),
    ("heredoc text", "cat <<EOF\ngh pr merge 12\nEOF", False),
    ("quoted delimiter", "cat <<'EOF'\ngh pr merge 12\nEOF", False),
    ("tab-stripped delimiter", "cat <<-EOF\ngh pr merge 12\n\tEOF", False),
    # board_locks has always dropped shell-fed heredocs too; other guards inspect their bodies.
    ("shell heredoc keeps lock-hook semantics", "bash <<EOF\ngh pr merge 12\nEOF", False),
    ("piped heredoc keeps lock-hook semantics", "cat <<EOF | bash\ngh pr merge 12\nEOF", False),
    ("merge after heredoc", "cat <<EOF\ntext\nEOF\n; gh pr merge 12", True),
    ("merge before heredoc", "gh pr merge 12; cat <<EOF\ntext\nEOF", True),
    ("multiple heredocs", "cat <<A\ngh pr merge 12\nA\n; cat <<B\ngh pr merge 12\nB", False),
]
for name, command, denied in cases:
    event = {"tool_name": "Bash", "session_id": "me", "cwd": str(home), "tool_input": {"command": command}}
    start = time.monotonic()
    try:
        p = subprocess.run([sys.executable, str(hooks / "board_locks.py")], input=json.dumps(event),
                           text=True, capture_output=True, env=env, timeout=1)
        elapsed = time.monotonic() - start
        out = json.loads(p.stdout) if p.stdout.strip() else {}
        actual = out.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
        assert elapsed < 1, f"took {elapsed:.3f}s"
        assert p.returncode == 0 and not p.stderr, (p.returncode, p.stderr)
        assert actual == denied, (actual, denied, out)
        print(f"PASS {name} ({elapsed:.3f}s)")
    except (subprocess.TimeoutExpired, AssertionError, ValueError) as e:
        failed += 1
        print(f"FAIL {name}: {e}")
sys.exit(bool(failed))
PY
check $? 0 "board_locks heredoc latency and decisions"
exit $fail
