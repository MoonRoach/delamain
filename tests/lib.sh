# Shared helpers for the Delamain test scripts (bash). Source it: . "$(dirname "$0")/lib.sh"
# Every test runs against a throw-away hub home; nothing here may touch the real one.
set -u
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="${BIN:-$(cd "$T/../bin" && pwd)}"
HOOKS="$(cd "$T/../hooks" && pwd)"
export AGENT_HUB_TZ=UTC
unset HUB_TAG HUB_STAGE CLAUDE_CODE_SESSION_ID AGENT_SESSION_ID AGENT_BOARD_FILE AGENT_HUB_LOCK_RULES CLAUDE_SESSIONS_DIR \
      AGENT_HUB_MODEL_MAP AGENT_HUB_DEFAULT_EFFORT AGENT_HUB_PERMISSION_MODE CLAUDE_BIN \
      AGENT_HUB_DEFAULT_REPO AGENT_HUB_NIGHT AGENT_HUB_SEND_CAP AGENT_HUB_HANDOFF_MAX_BYTES AGENT_INIT_TIMEOUT \
      AGENT_HUB_TAKE_MAIN_MERGE AGENT_HUB_JWAIT_MATCH AGENT_HUB_JWAIT_FOR AGENT_HUB_BG_WAIT_CEILING_MS CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS \
      CLAUDE_CONFIG_DIR CODEX_THREAD_ID AGENT_SESSION_ID AGENT_HUB_ENGINE CODEX_BIN \
      AGENT_HUB_CODEX_MODEL_MAP AGENT_HUB_CODEX_DEFAULT_MODEL AGENT_HUB_CODEX_PERMISSION_MODE AGENT_HUB_CODEX_HOOK_TRUST \
      AGENT_HUB_SUCCESSOR_ENGINE CLAUDE_EFFORT CLAUDE_CODE_HOST_SESSION_ID \
      AGENT_HUB_EFFORT_DEFAULTS AGENT_HUB_REASON_MODELS AGENT_HUB_REASON_POLICY AGENT_HUB_RESUME_MAX_CTX \
      AGENT_HUB_SPAWN_HOLD_LOAD AGENT_HUB_SPAWN_HOLD AGENT_HUB_WATCHDOG_LOAD
# `hub start` / `hub takeover` refuse to run outside a fresh worktree of a project (exit 4); the scripts run them in
# throw-away directories with no repository, so they opt out the way a scripted environment does. t_location.sh and
# t_project_warn.sh unset it.
export AGENT_HUB_NO_PROJECT=1
# `hub start` refuses a stage name with no word about the work and wants --goal; the scripts start stages called s1, web,
# stage-a, so they opt out the same way. t_naming.sh unsets it.
export AGENT_HUB_NO_NAMING=1
# The limit-pace advisor (bin/limit_pace.py) reads plan usage from $CODEX_HOME/sessions: the machine's real Codex week
# must not decide whether a test's spawn is refused. A script that needs Codex data sets CODEX_HOME itself.
export CODEX_HOME="$(mktemp -d)"
fail=0
check(){ if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got $1 want $2)"; fail=1; fi; }
new_home(){ export AGENT_HUB_HOME="$(mktemp -d)"; }
today(){ date -u +%F; }
# UTC clock arithmetic, portable (no GNU/BSD date flags): utc_iso -2 -> ISO minute two minutes ago
utc_iso(){ python3 -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M"))' "$1"; }
utc_hhmm(){ python3 -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=int(sys.argv[1]))).strftime("%H:%M"))' "$1"; }
# a clock time n seconds from now (may be negative): utc_hms 4 -> 20:23:34; utc_iso_s 4 -> 2026-10-04T20:23:34
utc_hms(){ python3 -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)+d.timedelta(seconds=int(sys.argv[1]))).strftime("%H:%M:%S"))' "$1"; }
utc_iso_s(){ python3 -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)+d.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S"))' "$1"; }
# bounded SECS cmd...: run a command with a hard time limit, portable (no GNU timeout on macOS runners); exit 124 on timeout
bounded(){ python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}
# armed FILE: wait (bounded, 60 s) until the jwait writing to FILE has printed its "waiting for" line, which comes after its
# baseline read of the journal; a line written before that is not news to it. Fails the check if jwait never gets there.
armed(){ local i; for i in $(seq 1 600); do grep -q '^jwait \[.*\]: waiting for' "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
journal(){ echo "$AGENT_HUB_HOME/${1:-stage-a}/coordinator/work/journal-$(today).md"; }
# in-place regex substitution on a file, portable (no sed -i flavours)
subst(){ python3 - "$1" "$2" "$3" <<'PY'
import re, sys
p, pat, rep = sys.argv[1:]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(pat, rep, s, flags=re.M))
PY
}
# hash of every file under a dir (lock files and test outputs excluded)
snap(){ python3 - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha1()
for d, _, files in sorted(os.walk(sys.argv[1])):
    if "/.jwait-state" in d:
        continue
    for f in sorted(files):
        if f.endswith((".lock", ".out")):
            continue
        h.update(f.encode()); h.update(open(os.path.join(d, f), "rb").read())
print(h.hexdigest())
PY
}

# fake_ps TABLE: prints a PATH directory whose ps(1) answers from TABLE ("pid ppid command…" per line; pid `*` = whatever
# pid is asked for first, the caller's parent), so the effort tests never see the real claude that runs them
fake_ps(){ local d; d="$(mktemp -d)"; printf '#!/bin/sh\nFAKE_PS_TABLE="%s" exec python3 "%s/fake_ps.py" "$@"\n' "$1" "$T" > "$d/ps"; chmod +x "$d/ps"; echo "$d"; }
