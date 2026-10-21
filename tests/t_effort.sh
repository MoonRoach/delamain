#!/bin/bash
# `hub effort` / bin/session_effort.py: the effort a Claude Code session runs at now. One check per source (the hook input,
# $CLAUDE_EFFORT, the transcript, a `--bg` session's state.json, the Desktop record, the process argv), the order they are
# read in, the sources that go stale (argv after an in-session /effort), the sources that must not be trusted (variables
# a session's children inherit), another session by id, a Codex session, and the refusal when nothing answers.
# The fixtures have the shape the CLI 2.1.289 writes (probed with throw-away sessions at a known effort, then after /effort);
# the process table is tests/fake_ps.py, so no real claude process is ever read.
. "$(dirname "$0")/lib.sh"
unset CLAUDE_JOB_DIR CLAUDE_PID
W=$(mktemp -d); CFG=$(mktemp -d); export CLAUDE_CONFIG_DIR=$CFG CLAUDE_SESSIONS_DIR=$(mktemp -d)
SID=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa; OTHER=bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb
export CLAUDE_CODE_SESSION_ID=$SID
PSTAB=$(mktemp); NO_PS=$(fake_ps $PSTAB)  # the process table; empty = no claude among the ancestors
CLAUDE=/opt/homebrew/bin/claude

reset(){ rm -rf "$CFG"/projects "$CFG"/jobs "$CLAUDE_SESSIONS_DIR"/*; : > $PSTAB; unset CLAUDE_EFFORT; }
# transcript SESSION EFFORT [MODEL]: a main-thread assistant record at that effort (EFFORT "-" = a record without one)
transcript(){ mkdir -p "$CFG/projects/-x"; python3 - "$CFG/projects/-x/$1.jsonl" "$2" "${3:-claude-opus-5-5}" <<'PY'
import json, sys
rec = {"type": "assistant", "isSidechain": False, "message": {"model": sys.argv[3], "usage": {"input_tokens": 5}}}
if sys.argv[2] != "-":
    rec.update(effort=sys.argv[2], perTurnEffort=sys.argv[2])
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n" + json.dumps(rec) + "\n")
PY
}
# job SESSION FLAGS…: ~/.claude/jobs/<first 8>/state.json of a `claude --bg` session with these respawnFlags
job(){ local sid=$1; shift; mkdir -p "$CFG/jobs/${sid:0:8}"; python3 - "$CFG/jobs/${sid:0:8}/state.json" "$sid" "$@" <<'PY'
import json, sys
json.dump({"state": "working", "respawnFlags": sys.argv[3:], "sessionId": sys.argv[2], "daemonShort": sys.argv[2][:8], "template": "bg"}, open(sys.argv[1], "w"))
PY
}
# desktop LOCAL_ID CLI_SESSION EFFORT: a Desktop session record
desktop(){ mkdir -p "$CLAUDE_SESSIONS_DIR/org/acc"; python3 - "$CLAUDE_SESSIONS_DIR/org/acc/$1.json" "$1" "$2" "$3" <<'PY'
import json, sys
json.dump({"sessionId": sys.argv[2], "cliSessionId": sys.argv[3], "effort": sys.argv[4], "model": "claude-opus-5-5"}, open(sys.argv[1], "w"))
PY
}
# ps_claude CMD…: the ancestors of a command: the tool's shell, then this claude process
ps_claude(){ printf '* 7000 /bin/zsh -c source /snap.sh && eval cmd\n7000 1 %s\n' "$*" > $PSTAB; }
hub_effort(){ PATH=$NO_PS:$PATH $B/hub effort "$@"; }
# answer [args]: "<effort> <source>" from --json, "none" when no source answers (exit 1 with the JSON), CRASH on a traceback
answer(){ local out; out=$(hub_effort --json "$@" 2>$W/answer.err)
  if grep -q Traceback $W/answer.err; then echo CRASH; return; fi
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("none" if d["effort"] is None else d["effort"] + " " + d["source"])' 2>/dev/null || echo none; }

# ================================================================== one source at a time
reset; CLAUDE_EFFORT=low answer | grep -qx 'low env'; check $? 0 "env: \$CLAUDE_EFFORT of the Bash tool"
reset; CLAUDE_EFFORT=auto; export CLAUDE_EFFORT; check "$(answer)" none "env: a value that is not an effort level is no answer"
reset; transcript $SID medium; check "$(answer)" "medium transcript" "transcript: effort of the last assistant record"
reset; transcript $SID high; transcript $SID -; check "$(answer)" none "transcript: the last record has no effort (a model without one) — not the one before it"
reset; transcript $SID xhigh; python3 - "$CFG/projects/-x/$SID.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:   # a sidechain record and an API-error record after the real one
    f.write(json.dumps({"type": "assistant", "isSidechain": True, "message": {"model": "claude-haiku-4-5"}, "effort": "low"}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"model": "<synthetic>"}}) + "\n")
PY
check "$(answer)" "xhigh transcript" "transcript: sidechain and synthetic records are skipped"
reset; job $SID --remote-control -n "Hub x #2" --effort high --permission-mode bypassPermissions --model claude-opus-5-5; check "$(answer)" "high job" "job: --effort of respawnFlags in jobs/<id>/state.json (a --bg session)"
reset; job $SID --permission-mode bypassPermissions --effort high --model opus --effort low; check "$(answer)" "low job" "job: the last --effort wins (/effort appends its own)"
reset; job $SID --permission-mode bypassPermissions --model opus; check "$(answer)" none "job: respawnFlags without --effort — no answer"
reset; job $OTHER --effort max; mv "$CFG/jobs/${OTHER:0:8}" "$CFG/jobs/${SID:0:8}"; check "$(answer)" none "job: a state.json that names another session is not this one's"
reset; job $OTHER --effort max; job $SID --effort low; check "$(CLAUDE_JOB_DIR=$CFG/jobs/${OTHER:0:8} answer)" "low job" "job: \$CLAUDE_JOB_DIR is not used (a child inherits its ancestor's)"
reset; desktop local_1111 $SID xhigh; check "$(answer)" "xhigh desktop" "desktop: effort of the record whose cliSessionId is the session"
reset; desktop local_2222 $OTHER max; check "$(answer)" none "desktop: another session's record is not this one's"
reset; desktop local_2222 $OTHER max; desktop local_1111 $SID low; check "$(CLAUDE_CODE_HOST_SESSION_ID=local_2222 answer)" "low desktop" "desktop: \$CLAUDE_CODE_HOST_SESSION_ID is only a hint (a child inherits its ancestor's); the record is checked"
reset; desktop local_1111 $SID bogus; check "$(answer)" none "desktop: a bad value in the record is no answer"
reset; ps_claude $CLAUDE --session-id $SID --model opus --effort max --output-format stream-json; check "$(answer)" "max argv" "argv: --effort of the nearest claude ancestor"
reset; ps_claude $CLAUDE --session-id $SID --model sonnet --effort xhigh -n "perf" -p '# Brief: start it with --effort low and --effort max'; check "$(answer)" "xhigh argv" "argv: --effort in the prompt after -p is not a flag"
reset; ps_claude '/Users/x/Library/Application Support/Claude/claude-code/2.1.286/f23/claude.app/Contents/MacOS/claude --output-format stream-json --input-format stream-json --effort xhigh --model claude-opus-5-5'; check "$(answer)" "xhigh argv" "argv: a Desktop CLI (path with spaces)"
reset; ps_claude claude bg-spare --bg-spare /tmp/cc-daemon/spare/ac28af6f.claim.sock; check "$(answer)" none "argv: a --bg session's process carries no --effort — no answer (not a guess)"
reset; ps_claude $CLAUDE --session-id $SID --model opus; check "$(answer)" none "argv: started on the default (no flag) — no answer"
reset; ps_claude $CLAUDE --session-id $SID --effort ultra; check "$(answer)" none "argv: a value that is not an effort level is no answer"
reset; printf '* 7000 /bin/zsh -c x\n7000 1 /usr/bin/python3 /x/not-claude.py --effort max\n' > $PSTAB; check "$(answer)" none "argv: an ancestor that is not claude is not read"

# ================================================================== a --bg session: its environment is the daemon's
# `claude daemon run` hands its own environment (CLAUDE_EFFORT, CLAUDE_CODE_HOST_SESSION_ID, HUB_BIN) to every session it starts
reset; export CLAUDE_EFFORT=high; job $SID --effort medium --model opus; desktop local_2222 $OTHER max
check "$(CLAUDE_CODE_HOST_SESSION_ID=local_2222 answer)" "medium job" "bg: the daemon's \$CLAUDE_EFFORT and Desktop id are not read; the job answers"
transcript $SID low; check "$(CLAUDE_CODE_HOST_SESSION_ID=local_2222 answer)" "low transcript" "bg: …and the transcript (the last turn) outranks the job"
rm -rf "$CFG/jobs"; check "$(answer)" "high env" "bg control: without a job for the session the same environment is read"
unset CLAUDE_EFFORT

# ================================================================== a model without an effort setting (Haiku 4.5): nothing is its effort
# The CLI sets $CLAUDE_EFFORT only for a model that has the setting; on Haiku 4.5 the Bash tool shows what an ancestor had.
# Haiku 5.5 has the setting and is read like any other model (last block of this section; probed on CLI 2.1.296).
reset; transcript $SID - claude-haiku-4-5-20251001; export CLAUDE_EFFORT=xhigh
job $SID --effort high; desktop local_1111 $SID medium; ps_claude $CLAUDE --session-id $SID --model haiku --effort max
check "$(answer)" none "haiku 4.5: an inherited \$CLAUDE_EFFORT, the job, the record and the argv flag are none of them its effort"
hub_effort > $W/haiku.out 2>&1; check "$(grep -o 'the last turn ran on claude-haiku-4-5-20251001, which recorded no effort' $W/haiku.out | wc -l | tr -d ' ')" 4 "haiku 4.5: …and the refusal says why for each of the four"
check "$(PATH=$NO_PS:$PATH python3 - "$B" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import session_effort as se
print(se.current_effort(hook="low"))
PY
)" "('low', 'hook')" "haiku 4.5: …except a hook input that carries an effort (the CLI sends one only for a model that has it)"
reset; transcript $SID - claude-opus-5-5; export CLAUDE_EFFORT=high
check "$(answer)" "high env" "haiku 4.5 control: an Opus record with no effort field (an older CLI) does not discard the environment"
reset; transcript $SID xhigh claude-opus-5-5; transcript $SID - claude-haiku-4-5-20251001; export CLAUDE_EFFORT=xhigh
check "$(answer)" none "haiku 4.5: switched to Haiku in the session (the earlier Opus turns do not count)"
reset; transcript $SID - claude-haiku-4-5-20251001; transcript $SID low claude-sonnet-5-5; export CLAUDE_EFFORT=low
check "$(answer)" "low env" "haiku 4.5: switched back to a model with the setting — the environment answers again"
# Haiku 5.5: the record carries the effort, the CLI sets $CLAUDE_EFFORT from it and sends it in the hook input
reset; transcript $SID medium claude-haiku-5-5; export CLAUDE_EFFORT=medium
check "$(answer)" "medium env" "haiku 5.5: its \$CLAUDE_EFFORT is the effort (the opposite of Haiku 4.5)"
unset CLAUDE_EFFORT; check "$(answer)" "medium transcript" "haiku 5.5: …and so is the effort of its last record"
reset; transcript $SID low claude-haiku-5-5; job $SID --effort high; desktop local_1111 $SID medium; ps_claude $CLAUDE --session-id $SID --model haiku --effort max
check "$(answer)" "low transcript" "haiku 5.5 control: the same job, record and argv flag as in the Haiku 4.5 case above do not hide the record's effort"
unset CLAUDE_EFFORT

# ================================================================== the order: most current first
reset; export CLAUDE_EFFORT=low
transcript $SID medium; desktop local_1111 $SID xhigh; ps_claude $CLAUDE --session-id $SID --effort max
check "$(answer)" "low env" "order: env first …"
unset CLAUDE_EFFORT;                   check "$(answer)" "medium transcript" "order: … then the transcript …"
rm -rf "$CFG/projects";                check "$(answer)" "xhigh desktop" "order: … then the Desktop record …"
rm -rf "$CLAUDE_SESSIONS_DIR"/*;       check "$(answer)" "max argv" "order: … the process argv last …"
: > $PSTAB;                            check "$(answer)" none "order: … and nothing is nothing"
# a --bg session (it has a job): no env; the transcript, then the job, then the rest
reset; export CLAUDE_EFFORT=low
transcript $SID medium; job $SID --effort high; desktop local_1111 $SID xhigh; ps_claude $CLAUDE --session-id $SID --effort max
check "$(answer)" "medium transcript" "order, bg: the transcript first (the daemon's \$CLAUDE_EFFORT is skipped) …"
rm -rf "$CFG/projects";                check "$(answer)" "high job" "order, bg: … then the job …"
rm -rf "$CFG/jobs";                    check "$(answer)" "low env" "order, bg: … (without its job the same session reads the environment) …"
unset CLAUDE_EFFORT;                   check "$(answer)" "xhigh desktop" "order, bg: … then the Desktop record …"
reset; export CLAUDE_EFFORT=low
check "$(PATH=$NO_PS:$PATH python3 - "$B" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import session_effort as se
print(se.current_effort(hook="max"), se.current_effort(hook="bogus"), se.current_effort(hook=None))
PY
)" "('max', 'hook') ('low', 'env') ('low', 'env')" "order: the hook input's effort.level beats env; a bad one is ignored"
unset CLAUDE_EFFORT

# ================================================================== a source that lags: argv after /effort
reset; transcript $SID high; ps_claude $CLAUDE --session-id $SID --effort low
check "$(answer)" "high transcript" "stale: the process was started at low, /effort made it high — the transcript wins over the argv"
hub_effort > $W/stale.out 2>&1; grep -qx 'note: argv says low (the process argv is fixed at launch: it lags an in-session change)' $W/stale.out; check $? 0 "stale: …and the output says the argv disagrees and why"
reset; job $SID --effort high --effort medium; ps_claude $CLAUDE --session-id $SID --effort low
check "$(answer)" "medium job" "stale: a --bg session after /effort — the job's respawnFlags win over the argv"
reset; transcript $SID low; transcript $SID max; check "$(answer)" "max transcript" "stale: the transcript is read from its tail, the last turn"

# ================================================================== human output and --json
reset; export CLAUDE_EFFORT=xhigh; transcript $SID xhigh
hub_effort > $W/h.out 2>&1; rc=$?; check "$rc:$(head -1 $W/h.out)" "0:xhigh  (source: env — \$CLAUDE_EFFORT)" "output: the effort and its source on the first line; sources that agree are not repeated"
check "$(wc -l < $W/h.out | tr -d ' ')" 1 "output: …nothing else when nothing disagrees"
hub_effort --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["effort"], d["source"], [r["source"] for r in d["readings"]], d["readings"][2]["effort"])' > $W/j.out
check "$(cat $W/j.out)" "xhigh env ['hook', 'env', 'transcript', 'job', 'desktop', 'argv'] xhigh" "--json: the answer, and every source's reading in order"
unset CLAUDE_EFFORT

# ================================================================== another session; Desktop ids; self
reset; export CLAUDE_EFFORT=low; transcript $OTHER xhigh
check "$(answer --session $OTHER)" "xhigh transcript" "--session: another session's effort — the caller's \$CLAUDE_EFFORT is not its"
check "$(answer --session $SID)" "low env" "--session with the caller's own id is the caller"
check "$(answer --session self)" "low env" "--session self is the caller"
unset CLAUDE_EFFORT
reset; printf '4242 1 %s --session-id %s --effort max\n' $CLAUDE $OTHER > $PSTAB
check "$(answer --session $OTHER)" "max argv" "--session: another session's process found by --session-id"
# another process's prompt may quote the flag: only the launch options (before the prompt) name a session
reset; printf '4242 1 %s --session-id %s --effort high -n worker -p Example for the docs: %s --session-id %s --effort max\n' $CLAUDE $SID $CLAUDE $OTHER > $PSTAB
check "$(answer --session $OTHER)" none "--session: a prompt that quotes \`--session-id B\` does not make that process B's"
printf '4242 1 %s --session-id %s --effort max -n worker -p Reminder: --session-id %s --effort low\n' $CLAUDE $OTHER $OTHER > $PSTAB
check "$(answer --session $OTHER)" "max argv" "positive control: the launch option --session-id B before the prompt is B's, and its --effort is read from the options too"
printf '4242 1 %s --resume %s --effort low\n4243 1 %s --session-id %s-extra --effort max\n' $CLAUDE $OTHER $CLAUDE $OTHER > $PSTAB
check "$(answer --session $OTHER)" "low argv" "--resume B counts; a longer id that merely starts with B does not"
reset; desktop local_3333 $OTHER high; transcript $OTHER xhigh
check "$(answer --session local_3333)" "xhigh transcript" "--session local_…: the Desktop record names the CLI session"
hub_effort --session local_9999 > $W/nolocal.out 2>&1; check "$?:$(grep -c 'no Desktop session record for local_9999' $W/nolocal.out)" "1:1" "--session local_…: an unknown Desktop session is an error"

# ================================================================== nothing answers: exit 1, every source named
reset; hub_effort > $W/none.out 2>&1; rc=$?
check "$rc" 1 "refusal: no source answers → exit 1"
grep -q '^FAILED: effort undetermined; tried hook: .*; env: \$CLAUDE_EFFORT is not set; transcript: .*; job: .*; desktop: .*; argv: no claude process among the ancestors' $W/none.out; check $? 0 "refusal: …naming every source tried"
reset; hub_effort --json > $W/none.json 2>/dev/null; rc=$?; check "$rc:$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["effort"], d["source"])' $W/none.json)" "1:None None" "refusal: --json says null/null (and still exits 1)"
( unset CLAUDE_CODE_SESSION_ID; reset; hub_effort > $W/nosid.out 2>&1; echo $? > $W/nosid.rc ); check "$(cat $W/nosid.rc)" 1 "refusal: no session id and nothing in the environment"
grep -q 'no session id' $W/nosid.out; check $? 0 "…and it says the session id is missing"

# ================================================================== a Codex session is not read as a Claude one
reset; export CLAUDE_EFFORT=high; transcript $SID medium; ps_claude $CLAUDE --session-id $SID --effort max
check "$(AGENT_HUB_ENGINE=codex answer)" none "codex: \$CLAUDE_EFFORT (its launcher's), transcripts and argv are not the Codex session's effort"
check "$(CODEX_THREAD_ID=thr-1 answer)" none "codex: CODEX_THREAD_ID makes it a Codex session as well"
unset CLAUDE_EFFORT

exit $fail
