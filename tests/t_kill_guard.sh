#!/bin/bash
# Headless agents outlive the session that spawned them, and a pattern kill — the one thing that still reaches them —
# is refused. (1) `agent spawn` from a stand-in host that stays alive (its own session, like a desktop app): SIGTERM and
# SIGHUP to the host's process group, the host alone, and the host's group killed while spawn still waits for the
# init event — the agent lives, for both engines; `agent stop` still stops it. (2) hooks/kill_guard.py: the command that
# killed four agents and Claude Desktop on 14.10 is denied, every other kill by name or pattern too; quoted text, a pid
# kill and `pgrep` alone pass. On macOS the hazard itself is shown read-only with `pgrep`.
. "$(dirname "$0")/lib.sh"
unset AGENT_HUB_KILL_GUARD AGENT_HUB_KILL_ESCAPE
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
pid_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pid') or '')" $R/stage-a/agents/$1/meta.json 2>/dev/null; }
alive(){ kill -0 "$1" 2>/dev/null; }
gone(){ local i; for i in $(seq 1 50); do alive "$1" || return 0; sleep 0.2; done; return 1; }

# ================================================================== 1. the agent outlives its host
# host ROLE ENGINE [INIT_DELAY]: a stand-in host in its own session runs `agent spawn` and stays alive like an app;
# prints "<host pid> <spawn exit>" once spawn returns (or "<host pid> bg" with an init delay: spawn still waits).
host(){
  local out=$R/host-$1.out
  FAKE_HOLD=30 FAKE_CODEX_HOLD=30 FAKE_INIT_DELAY=${3:-0} python3 - "$B/agent-spawn" "$1" "$2" "$W" "${3:-0}" > $out 2>$R/host-$1.err <<'PY' &
import os, subprocess, sys, time
spawn, role, engine, w, delay = sys.argv[1:]
os.setsid()
cmd = [spawn, "--engine", engine, "--role", role, "--cwd", w, "--brief", w + "/b.md"]
cmd += ["--model", "haiku"] if engine == "claude" else []
if float(delay):
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(os.getpid(), "bg", flush=True)
else:
    r = subprocess.run(cmd, capture_output=True, text=True)
    sys.stderr.write(r.stdout + r.stderr)
    print(os.getpid(), r.returncode, flush=True)
time.sleep(60)
PY
  local i; for i in $(seq 1 150); do [ -s $out ] && break; sleep 0.2; done
  cat $out
}

HOSTS=()
read HP RC <<<"$(host term claude)"; HOSTS+=($HP); check "$RC" 0 "spawn from a live host exits 0"
PID=$(pid_of term)
kill -TERM -- -$HP; sleep 1
alive $PID; check $? 0 "SIGTERM to the host's process group: the agent lives"
alive $HP; check $? 1 "  (control: the host itself is gone)"
check "$(python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' $PID 2>/dev/null)" "$PID" "the agent leads its own session (no controlling terminal of the host)"

read HP RC <<<"$(host hup claude)"; HOSTS+=($HP); check "$RC" 0 "spawn for the SIGHUP case"
PID=$(pid_of hup)
kill -HUP -- -$HP; sleep 1
alive $PID; check $? 0 "SIGHUP to the host's process group: the agent lives"

read HP RC <<<"$(host parent claude)"; HOSTS+=($HP); check "$RC" 0 "spawn for the host-alone case"
PID=$(pid_of parent)
kill -TERM $HP; sleep 1
alive $PID; check $? 0 "SIGTERM to the host alone: the agent lives"

read HP RC <<<"$(host cdx codex)"; HOSTS+=($HP); check "$RC" 0 "codex spawn from a live host exits 0"
PID=$(pid_of cdx)
kill -TERM -- -$HP; kill -HUP -- -$HP 2>/dev/null; sleep 1
alive $PID; check $? 0 "codex executor: SIGTERM and SIGHUP to the host's group, the agent lives"

# killed while `agent spawn` still waits for the init event: the run is already on record and keeps going
read HP RC <<<"$(host early claude 3)"; HOSTS+=($HP); check "$RC" bg "host started spawn and did not wait"
PID=""; for i in $(seq 1 50); do PID=$(pid_of early); [ -n "$PID" ] && break; sleep 0.2; done
kill -TERM -- -$HP; sleep 4
[ -n "$PID" ] && alive $PID; check $? 0 "host's group killed during the init wait: the recorded agent lives"

# stop stays possible, through `agent stop`, by the recorded pid and group
for role in term hup parent cdx early; do
  PID=$(pid_of $role)
  $B/agent stop $role > $R/stop-$role.out 2>&1; check $? 0 "agent stop $role"
  gone $PID; check $? 0 "  $role is gone after agent stop"
done
for h in ${HOSTS[@]+"${HOSTS[@]}"}; do kill -KILL -- -$h 2>/dev/null; done

# ================================================================== 2. the kill guard
kg(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/","tool_input":{"command":sys.argv[1],"run_in_background":sys.argv[2]=="1"}}))' "$1" "${2:-0}" | python3 $HOOKS/kill_guard.py; }
denied(){ kg "$@" | grep -q '"permissionDecision": "deny"'; }
INCIDENT='bash tests/t_await.sh 2>&1 | grep -v ^PASS; echo suite-done; pkill -f "[s]leep 300" -P 1 2>/dev/null; true'
denied "$INCIDENT"; check $? 0 "the 14.10 command is denied"
kg "$INCIDENT" | grep -q 'more patterns'; check $? 0 "  and the reason names the option-after-pattern trap"
denied "$INCIDENT  # kill-ok: my sleeps"; check $? 0 "  the escape comment does not pass the trap"
denied "$INCIDENT" 1; check $? 0 "  a background command is denied too"
BLOCKED=(
  'pkill -f "[s]leep 300"'
  'pkill -9 -f hang.sh'
  'killall node'
  'sudo killall -9 claude'
  '/usr/bin/pkill -x Foo'
  'timeout 5 pkill -f x'
  'if ! pkill -f x; then echo none; fi'
  'bash -c "pkill -f worker"'
  "echo 'pkill -f x' | sh"
  'kill $(pgrep -f worker)'
  'kill -9 "$(pgrep -f worker)"'
  'kill `pgrep -f worker`'
  'pgrep -f worker | xargs kill'
  'pgrep -f worker | xargs -r kill -9'
  # M1: pidof and grep on ps output are pid sources too, in $(…), backticks and pipes, at any stage of the pipeline
  'kill $(pidof node)'
  'kill `pidof node`'
  'pidof node | xargs kill'
  "kill -9 \$(ps aux | grep worker | awk '{print \$2}')"
  "ps aux | grep worker | awk '{print \$2}' | xargs kill"
  'pgrep -f worker | sort | xargs kill'
  'kill $(echo $(pgrep -f worker))'
  'bash -c "pgrep -f worker | xargs kill"'
  # M2: the same kill split over statements of one command
  'for p in $(pgrep -f worker); do kill $p; done'
  'pgrep -f worker | while read p; do kill $p; done'
  'P=$(pgrep -f worker); kill $P'
  'export P=$(pidof node)
kill $P'
  'bash -c "for p in \$(pgrep -f w); do kill \$p; done"'
  # M3: a single & separates statements
  'pkill -x node &'
  'sleep 1 & pkill -x node'
  # L4, L5
  'eval pkill -f x'
  'eval "pkill -f x"'
  'killall5 -15'
  'echo $(date; pkill -f x)'
  'ssh host "pkill node" ; pkill -x local'
)
for c in "${BLOCKED[@]}"; do denied "$c"; check $? 0 "denied: $c"; done
ALLOWED=(
  'kill 12345'
  'kill -- -12345'
  'kill -TERM $!'
  'pgrep -lf "[s]leep 300"'
  'git commit -m "kill guard: deny pkill -f and killall"'
  'grep -n pkill bin/agent'
  'rg "killall|pkill" docs'
  'echo "pkill -f x"'
  "cat > notes.md <<'EOF'
pkill -f x
EOF"
  'ps aux | grep pkill'
  'P=$(pgrep -lf worker); echo $P'
  'pgrep -lf worker | sort'
  'pgrep -f worker | xargs echo'
  'kill $(cat /tmp/app.pid)'
  'kill $(cat pids | grep 1)'
  'ps aux | grep worker | wc -l; kill 4242'
  'for f in a b; do echo $f; done; kill 4242'
  'git commit -m "a; kill $(pgrep x)"'
  'sleep 5 & echo $!'
  'my-server > out.log 2>&1 &'
  'kill 4242 &'
  'cmd &> out.log; kill $!'
  # L7: a command that runs on another machine reaches no local process, in both forms
  'ssh host "pkill node"'
  'ssh host pkill -f x'
)
for c in "${ALLOWED[@]}"; do denied "$c"; check $? 1 "allowed: $(printf '%s' "$c" | head -1)"; done
denied 'pkill -x Foo  # kill-ok: restarting my own app'; check $? 1 "the escape comment passes a deliberate pattern kill"
denied 'pkill -x Foo &  # kill-ok: restarting my own app'; check $? 1 "  a background pkill takes the escape too (M3)"
kg 'pkill -x Foo &' | grep -q 'second pattern'; check $? 1 "  and a lone ampersand is not read as a second pattern"
denied 'for p in $(pgrep -f w); do kill $p; done  # kill-ok: my workers'; check $? 1 "the escape passes a loop kill (M2)"
denied 'kill $(pidof node)  # kill-ok: my node'; check $? 1 "the escape passes a pidof kill (M1)"
kg 'pkill -f x -P 1' | grep -q 'procps'; check $? 0 "the trap reason is true on Linux too: procps reads the option, BSD does not (L6)"
denied 'pkill -f "[s]leep 300" 2>/dev/null  # kill-ok: my test sleeps'; check $? 1 "  a redirection after the pattern is not read as a pattern"
AGENT_HUB_KILL_GUARD=off kg "$INCIDENT" | grep -q deny; check $? 1 "AGENT_HUB_KILL_GUARD=off turns it off"
echo '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' | python3 $HOOKS/kill_guard.py > $R/kg-read.out
check "$?:$(wc -c < $R/kg-read.out | tr -d ' ')" "0:0" "other tools untouched"

# the hazard, read-only: BSD pgrep/pkill read options only before the first pattern
if [ "$(uname)" = Darwin ]; then
  n_trap=$(pgrep -f "[n]o-such-process-kg" -P 1 | wc -l | tr -d ' ')
  n_ok=$(pgrep -f -P 1 "[n]o-such-process-kg" | wc -l | tr -d ' ')
  [ "$n_trap" -gt 0 ] && [ "$n_ok" = 0 ]; check $? 0 "macOS: an option after the pattern turns into patterns ($n_trap processes match, $n_ok with options first)"
fi
exit $fail
