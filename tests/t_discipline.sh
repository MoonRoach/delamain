#!/bin/bash
# Agent-discipline hooks: polling_guard (PreToolUse Bash), context_budget (UserPromptSubmit / PostToolUse /
# PreToolUse), delegation (SessionStart / UserPromptSubmit / PreToolUse Agent|Task|Workflow) and the shared subagent
# rules in `agent spawn`. Every decision has a positive and a negative control.
. "$(dirname "$0")/lib.sh"
unset AGENT_HUB_DELEGATION_LEVEL CLAUDE_PLUGIN_ROOT CLAUDE_CONFIG_DIR $(env | sed -n 's/^\(AGENT_HUB_\(CONTEXT\|DELEGATION\|EFFORT\|POLL\|CI_STATUS\|WAIT\|STATE\)[A-Z_]*\)=.*/\1/p')
new_home; R=$AGENT_HUB_HOME
EXAMPLE="$T/../docs/examples/subagent-policy.json"

# ================================================================== polling guard
# run the guard on one command; prints the hook's stdout. $2=1: run_in_background, $3: cwd
pg(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":sys.argv[3],"tool_input":{"command":sys.argv[1],"run_in_background":sys.argv[2]=="1"}}))' "$1" "${2:-0}" "${3:-/}" | python3 $HOOKS/polling_guard.py; }
denied(){ pg "$@" | grep -q '"permissionDecision": "deny"'; }
P="projects/acme%2Fwebapp"
# commands a session really ran while waiting (the reason this hook exists)
BLOCKED=(
  'until ! pgrep -f "pytest -n 4" > /dev/null; do sleep 20; done; sed -n "/short test summary/,$p" /tmp/out.txt'
  'until grep -qE "=====.*(passed|failed|error)" /tmp/full.txt 2>/dev/null; do sleep 20; done; cat /tmp/full.txt'
  'until [ -s /tmp/ci3.txt ] && grep -qE "^\[.*\] exit=" /tmp/ci3.txt; do sleep 20; done; tail -12 /tmp/ci3.txt'
  'for i in $(seq 1 60); do [ -f /tmp/pytest.exit ] && break; command sleep 20; done; echo "exit=$(cat /tmp/pytest.exit)"'
  'sleep 120; curl -s https://example.invalid/healthz'
  'while ! curl -fsS http://127.0.0.1:8000/healthz; do sleep 10; done'
)
ALLOWED=(
  'for i in $(seq 1 12); do BODY=$(curl -fsS --max-time 5 http://127.0.0.1:8000/healthz) && break; sleep 5; done; echo "$BODY"'
  'pytest -n auto tests/ledger'
  'sleep 5; docker compose ps'
  'git log --oneline -5 | grep -i sleep'
  'for f in lint target drift pytest; do echo "== $f"; tail -3 /tmp/$f.txt; done'
  'until ! pgrep -f "[p]ytest -n 4"; do sleep 20; done  # poll-ok: cutover gate, waiting by hand'
  "echo 'until ! pgrep -f \"pytest -n 4\"; do sleep 20; done' | python3 hooks/polling_guard.py"
  $'cat > /tmp/waiter.sh <<\'SH\'\nuntil [ -f /tmp/done ]; do sleep 30; done\nSH\nchmod +x /tmp/waiter.sh'
)
CI_BLOCKED=(
  "glab api \"$P/pipelines/123456\""
  "glab api $P/pipelines/123456/jobs?per_page=100"
  "glab api '$P/pipelines?ref=feature/x&per_page=1' | jq '.[0].status'"
  "glab api \"$P/merge_requests/499/pipelines\""
  "glab api $P/jobs/987654"
  "glab api --paginate $P/pipelines/latest"
  "glab ci status --branch feature/x"
  "glab ci get --pipeline-id 123"
  "glab ci list"
  "git push -q && glab api $P/pipelines/1"
  "gh run view 123456"
  "gh run list --branch feature/x"
  "gh run watch 123456"
  "gh pr checks 12"
  "gh api repos/acme/webapp/actions/runs/123456"
  "gh api repos/acme/webapp/commits/abc123/check-runs"
)
CI_ALLOWED=(
  "glab api \"$P/pipelines?sha=89e92129a3b4c5d6e7f8091a2b3c4d5e6f708192\""
  "glab api \"$P/pipelines?ref=feature/x&sha=\$SHA\""
  "glab api $P/jobs/987654/trace | tail -80"
  "glab api -X POST $P/jobs/987654/retry"
  "glab api --method POST $P/pipelines/1/cancel"
  "glab api \"$P/merge_requests/499\""
  "glab api \"$P/merge_requests?state=opened\""
  "glab mr create --remove-source-branch --yes -t x -d y"
  "glab ci trace 987654"
  "echo 'glab api $P/pipelines/1'"
  "glab api $P/pipelines/1  # poll-ok: one read after a manual retry"
  "gh run view 123456 --log-failed"
  "gh run view --job 42 --log"
  "gh run rerun 123456 --failed"
  "gh api repos/acme/webapp/actions/runs?head_sha=89e92129a3b4c5d6e7f8091a2b3c4d5e6f708192"
  "gh api repos/acme/webapp/actions/jobs/42/logs"
  "gh pr view 12"
)
i=0; for c in "${BLOCKED[@]}"; do i=$((i+1)); denied "$c"; check $? 0 "poll: wait $i denied"; denied "$c" 1; check $? 1 "poll: wait $i in the background passes"; done
i=0; for c in "${ALLOWED[@]}"; do i=$((i+1)); denied "$c"; check $? 1 "poll: normal work $i passes"; done
i=0; for c in "${CI_BLOCKED[@]}"; do i=$((i+1)); denied "$c"; check $? 0 "poll: CI status read $i denied"; denied "$c" 1; check $? 1 "poll: CI read $i in the background passes"; done
i=0; for c in "${CI_ALLOWED[@]}"; do i=$((i+1)); denied "$c"; check $? 1 "poll: CI lookup/log/action $i passes"; done
# `await` without --wait returns at once, its supervisor does the waiting: the CI command inside it is the recommended
# wait, not a read by hand. With --wait it holds the foreground, so it stays denied; a read outside the await still is.
denied 'await --ok MERGED --label "PR #12" -- gh pr checks 12 --watch --fail-fast'; check $? 1 "poll: a detached await of gh pr checks passes"
denied '$HUB_BIN/await --ok PASSED --label x --on 2=TIMEOUT -- gh run watch 123 --exit-status'; check $? 1 "poll: …also by path"
denied 'await --wait --ok PASSED --label x -- gh pr checks 12 --watch'; check $? 0 "poll: await --wait in the foreground is still denied"
denied 'await --ok DONE -- gh pr checks 12 --watch; gh pr checks 12'; check $? 0 "poll: …a read next to a detached await is still denied"
denied 'echo await -- gh pr checks 12'; check $? 1 "poll: (control) text of echo is not read"
# review of PR #140: the exception is for ONE detached await, read from the shell's own tokens
denied 'await "--wait" -- gh pr checks 12 --watch'; check $? 0 "poll: a quoted \"--wait\" is still --wait"
denied "await '--wait' -- gh pr checks 12 --watch"; check $? 0 "poll: …single quotes too"
denied 'await --wait -- gh pr checks 12 --watch'; check $? 0 "poll: …and the plain --wait"
for op in '&' ';' '&&' '||' '|' $'\n'; do
  denied "await --ok DONE -- true $op gh pr checks 12"; check $? 0 "poll: a control operator [$op] after a detached await ends the exception"
done
denied 'await -- true $(gh pr checks 12)'; check $? 0 "poll: a substitution inside a detached await is a read by hand"
denied 'await -- true `gh pr checks 12`'; check $? 0 "poll: …a backtick too"
denied '(await -- true) & gh pr checks 12'; check $? 0 "poll: a group around it does not keep the exception"
denied 'await --ok PASSED --label "PR 12" -- gh pr checks 12 --watch >/tmp/w.out 2>&1'; check $? 1 "poll: control — redirections do not end the exception"
denied 'await --ok PASSED -- gh pr checks 12 --watch &>/tmp/w.out'; check $? 1 "poll: …nor &>"
pg "${BLOCKED[0]}" | grep -q 'matches the waiting shell'; check $? 0 "poll: pgrep -f self-match is named"
pg "${BLOCKED[4]}" > $R/pg.out
grep -q 'jwait' $R/pg.out && grep -q 'run_in_background' $R/pg.out && grep -q 'poll-ok' $R/pg.out; check $? 0 "poll: the message names jwait, run_in_background and the marker"
echo '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' | python3 $HOOKS/polling_guard.py > $R/pg2.out; check "$?:$(wc -c < $R/pg2.out | tr -d ' ')" "0:0" "poll: other tools untouched"
echo 'not json' | python3 $HOOKS/polling_guard.py > $R/pg3.out 2>&1; check "$?:$(wc -c < $R/pg3.out | tr -d ' ')" "0:0" "poll: broken event fails open"
# configuration: project hint, thresholds, marker, own lists, switch off per repository
mkdir -p $R/repo/.git $R/repo/.agent-hub $R/other/.git
echo '{"AGENT_HUB_WAIT_HINT": "CI: make ci-wait PIPELINE=<id> with run_in_background: true", "AGENT_HUB_POLL_MAX_SLEEP": 200}' > $R/repo/.agent-hub/config.json
pg "glab ci status" 0 $R/repo | grep -q 'make ci-wait PIPELINE'; check $? 0 "poll: the repository's wait hint is in the message"
pg "glab ci status" 0 $R/other | grep -q 'make ci-wait'; check $? 1 "poll: …and only in that repository"
denied "sleep 120; ls" 0 $R/repo; check $? 1 "poll: the repository's max sleep (200 s) lets sleep 120 pass"
denied "sleep 120; ls" 0 $R/other; check $? 0 "poll: …the default (30 s) still denies it elsewhere"
echo '{"AGENT_HUB_POLL_GUARD": false}' > $R/repo/.agent-hub/config.json
denied "${BLOCKED[1]}" 0 $R/repo; check $? 1 "poll: switched off in the repository"
denied "${BLOCKED[1]}" 0 $R/other; check $? 0 "poll: …still on elsewhere"
echo '{"AGENT_HUB_POLL_ESCAPE": "wait-ok", "AGENT_HUB_CI_STATUS_DENY": ["\\bci-tool\\s+status\\b"], "AGENT_HUB_CI_STATUS_ALLOW": []}' > $R/repo/.agent-hub/config.json
denied "ci-tool status 12" 0 $R/repo; check $? 0 "poll: own deny list"
denied "glab ci status" 0 $R/repo; check $? 1 "poll: own deny list replaces the defaults"
denied "sleep 120  # wait-ok: deliberate" 0 $R/repo; check $? 1 "poll: own escape marker"
denied "sleep 120  # poll-ok: deliberate" 0 $R/repo; check $? 0 "poll: the default marker no longer applies there"
( export AGENT_HUB_POLL_GUARD=off; denied 'sleep 120' ); check $? 1 "poll: the environment switches it off"
python3 $HOOKS/polling_guard.py --defaults | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["AGENT_HUB_CI_STATUS_DENY"] and d["AGENT_HUB_CI_STATUS_ALLOW"]'; check $? 0 "poll: --defaults prints both lists"
# bypasses: a loop in quotes, text fed to a shell; sleep with a unit; a write with a field; marker and list fallbacks
BYPASS=(
  'timeout 600 bash -c "until [ -f /tmp/x ]; do sleep 20; done"'
  $'bash <<\'EOF\'\nuntil [ -f /tmp/done ]; do sleep 30; done\nEOF'
  $'cat <<\'EOF\' | sh\nuntil [ -f /tmp/done ]; do sleep 30; done\nEOF'
  "echo 'until [ -f /tmp/done ]; do sleep 30; done' | bash"
  "printf 'while true; do sleep 60; done' | xargs -0 sh -c"
  'sleep 5m; ls'
  'sleep 1h'
  'sleep 2d && echo done'
)
i=0; for c in "${BYPASS[@]}"; do i=$((i+1)); denied "$c"; check $? 0 "poll: bypass $i denied"; done
denied 'sleep 20s; ls'; check $? 1 "poll: sleep 20s passes"
denied 'sleep 0.25m; ls'; check $? 1 "poll: sleep 0.25m (15 s) passes"
denied "glab api $P/merge_requests/1/notes -f body=\"the jobs are green\""; check $? 1 "poll: glab api with a field is a write, not a status read"
denied "gh api repos/acme/webapp/issues/1/comments -F body=@pipelines.md"; check $? 1 "poll: gh api with a field is a write"
# quoted text is data until a shell executes it: 0.4.0 denied `git commit -m "… sleep 5m …"` and `grep "sleep 5m"`
DATA=(
  'git commit -m "fix: replace sleep 5m with ci_wait"'
  'grep -rn "sleep 5m" scripts/'
  'git commit -m "docs: never write while true; do sleep 60; done"'
  'rg "until .*; do"'
  'rg "until .*; do sleep 20"'
  'git commit -m "docs: do not write \$(sleep 5m) in text"'
  "rg 'sleep 60' app/"
  "git log --grep='sleep 60' --oneline -5"
  "sed -i 's/sleep 60/sleep 5/' scripts/wait.sh"
  'git commit -m "fix: until-loop; sleep 5m is not denied any more" -m "second paragraph"'
  'gh api repos/acme/webapp/issues/1/comments -f body="no: while true; do sleep 60; done"'
  "python3 -c \"print('sleep 5m')\""
  "bash -c \"git commit -m 'fix: while true; do sleep 60; done'\""
  "bash -c \"grep -rn 'sleep 5m' scripts/\""
  'echo "sleep 5m" | sudo -u app tee /tmp/waiter.sh'
  'echo "sleep 5m" | env -i grep bash'
  'echo "sleep 5m" | xargs echo'
  'echo "sleep 5m" > /tmp/waiter.sh'
  $'cat <<\'EOF\' | tee /tmp/waiter.sh\nuntil [ -f /tmp/done ]; do sleep 30; done\nEOF'
  $'git commit -m "$(cat <<\'EOF\'\nfix: bash -c "until x; do sleep 30; done", sleep 5m\nEOF\n)"'
  # the CI rules read a quoted string only where it carries an API path: a message that mentions `gh run view` is data
  "git commit -m 'ci: wrap gh run view in a script'"
  "grep 'gh run view' scripts/"
  "python3 -c \"print('gh run view 123')\""
  "bash -c \"git commit -m 'gh run view 123'\""
  # a group that goes nowhere near a shell, and stdin consumers that are not shells
  "(echo 'sleep 300'; echo ls) | cat"
  "echo 'sleep 300' | ssh host 'cat > /tmp/waiter.sh'"
  "echo 'sleep 300' | su -c cat"
  "echo 'sleep 300' | sudo -n tee /tmp/waiter.sh"
  "echo 'sleep 300' | command -v bash"
  "echo 'sleep 300' | timeout -k 5 600 cat"
)
i=0; for c in "${DATA[@]}"; do i=$((i+1)); denied "$c"; check $? 1 "poll: quoted data $i passes"; done
# …and a string a shell executes is checked: -c (with wrappers), eval, ssh, here-string, text piped to a shell, $(…)
RUN=(
  'eval "until [ -f /tmp/done ]; do sleep 20; done"'
  "bash <<< 'until [ -f /tmp/done ]; do sleep 30; done'"
  "docker exec ci sh -c 'until [ -f /tmp/done ]; do sleep 20; done'"
  "echo x | xargs -I{} sh -c 'until [ -f /tmp/{} ]; do sleep 20; done'"
  "bash -c \"bash -c 'until [ -f /tmp/done ]; do sleep 20; done'\""
  'OUT="$(until [ -f /tmp/done ]; do sleep 20; done; cat /tmp/done)"'
  'echo "$(until [ -f /tmp/done ]; do sleep 20; done)"'
  'git commit -m "docs: sleep 5m" && sleep 5m'
  "ssh dev-host 'until [ -f /tmp/done ]; do sleep 20; done'"
  "sh -c 'while ! curl -fsS http://127.0.0.1:8000/healthz; do sleep 10; done'"
  'env X=1 bash -lc "while true; do sleep 20; done"'
  'bash -c "sleep 120 && curl -s http://127.0.0.1:8000/healthz"'
  "echo 'until [ -f /tmp/done ]; do sleep 30; done' | sudo -u app bash"
  "echo 'until [ -f /tmp/done ]; do sleep 30; done' | /usr/bin/env bash"
  $'cat <<\'EOF\' | tee /tmp/waiter.sh | bash\nuntil [ -f /tmp/done ]; do sleep 30; done\nEOF'
  # one shell word made of several strings; a line continuation or a trailing `|` before the shell; a subshell
  "bash -c 'until [ -f '\"\$F\"' ]; do sleep 20; done'"
  "bash -c \"\$PRE\"'until [ -f /tmp/done ]; do sleep 20; done'"
  $'echo \'until [ -f /tmp/done ]; do sleep 20; done\' \\\n  | bash'
  $'echo \'until [ -f /tmp/done ]; do sleep 20; done\' |\n  bash'
  "(echo 'until [ -f /tmp/done ]; do sleep 20; done') | bash"
  # options of the shell between its name and `-c`
  "bash -eo pipefail -c 'until [ -f /tmp/done ]; do sleep 20; done'"
  "bash -o pipefail -c 'until [ -f /tmp/done ]; do sleep 20; done'"
  "bash -c -- 'until [ -f /tmp/done ]; do sleep 20; done'"
  # a here-string glued to `<<<`
  "bash <<<'sleep 300'"
  'bash <<<"sleep 300"'
  "sh<<<'until [ -f /tmp/done ]; do sleep 20; done'"
  # printing grouped in ( … ) or { …; } and piped to a shell; a group around the consumer
  "(echo 'sleep 300'; echo ls) | bash"
  "{ echo 'until [ -f /tmp/done ]; do sleep 20; done'; } | bash"
  "(bash <<< 'sleep 300')"
  "{ bash <<< 'sleep 300'; }"
  "echo 'sleep 300' | (bash)"
  # blank lines after the pipe
  $'echo \'sleep 300\' |\n\n bash'
  $'echo \'sleep 300\' |\n \n\n  bash'
  # other wrappers, `timeout` with flags, and stdin shells behind ssh / su / sudo -i / `. /dev/stdin`
  "echo 'sleep 300' | setsid bash"
  "echo 'sleep 300' | command bash"
  "echo 'sleep 300' | nice -n 10 bash"
  "echo 'sleep 300' | ionice -c 3 bash"
  "echo 'sleep 300' | stdbuf -o0 bash"
  "echo 'sleep 300' | doas bash"
  "echo 'sleep 300' | timeout -k 5 600 bash"
  "echo 'sleep 300' | sudo -n bash"
  "echo 'sleep 300' | sudo -i"
  "echo 'sleep 300' | su -"
  "echo 'sleep 300' | ssh host"
  "echo 'sleep 300' | ssh -p 22 host bash"
  "echo 'sleep 300' | . /dev/stdin"
)
i=0; for c in "${RUN[@]}"; do i=$((i+1)); denied "$c"; check $? 0 "poll: executed string $i denied"; denied "$c" 1; check $? 1 "poll: executed string $i in the background passes"; done
denied 'echo "$(gh run view 123456)"'; check $? 0 "poll: a CI status read in \$(…) under echo is denied"
denied 'git commit -m "$(gh run view 123456)"'; check $? 0 "poll: a CI status read in \$(…) in a commit message is denied"
denied 'bash -c "gh run view 123456"'; check $? 0 "poll: a CI status read inside bash -c is denied"
denied "echo 'gh run view 123456' | bash"; check $? 0 "poll: a CI status read piped to a shell is denied"
denied "gh run view 123456"; check $? 0 "poll: a plain CI status read is still denied"
pg "zsh -c 'until ! pgrep -f \"pytest -n 4\"; do sleep 20; done'" | grep -q 'matches the waiting shell'; check $? 0 "poll: a pgrep -f self-match inside bash -c is named"
pg "bash -c 'until ! pgrep -f \"[p]ytest -n 4\"; do sleep 20; done'" | grep -q 'matches the waiting shell'; check $? 1 "poll: …and the bracket trick inside bash -c is not"
python3 - "$HOOKS/polling_guard.py" <<'PY'; check $? 0 "poll: long and adversarial commands (quotes, strings, here-strings, flags) are judged within 5 s"
import json, subprocess, sys, time
# `<<< a` repeated: 0.4.0 read each as a heredoc opener and scanned to the end for its terminator, quadratically
# (about 10 s at 30000 repeats)
for cmd in ('bash -c ' + '"' * 40000, 'git commit -m "x" ' * 20000, 'xargs ' + '<<< "$a" ' * 10000,
            'xargs ' + '<<< a ' * 30000, "echo 'x' | sudo -u " + "-u " * 36 + "x",
            "echo x | ssh " + "-o a " * 5000 + "host", "(" * 3000 + "echo 'x'" + ")" * 3000 + " | bash"):
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/", "tool_input": {"command": cmd}})
    t = time.time()
    subprocess.run([sys.executable, sys.argv[1]], input=event, capture_output=True, text=True, timeout=60)
    assert time.time() - t < 5, (cmd[:20], time.time() - t)
PY
echo '{"AGENT_HUB_POLL_ESCAPE": "ok!"}' > $R/repo/.agent-hub/config.json
denied "sleep 120  # ok! deliberate" 0 $R/repo; check $? 1 "poll: an escape word ending in a non-word character works"
echo '{"AGENT_HUB_CI_STATUS_DENY": ["(unclosed", "[bad"]}' > $R/repo/.agent-hub/config.json
denied "glab ci status" 0 $R/repo; check $? 0 "poll: an all-invalid deny list falls back to the defaults"
echo '{"AGENT_HUB_CI_STATUS_DENY": []}' > $R/repo/.agent-hub/config.json
denied "glab ci status" 0 $R/repo; check $? 1 "poll: a deliberate empty list switches the CI rules off"
rm $R/repo/.agent-hub/config.json

# every jwait form the hub prints (takeover digest and the hub skill) passes the guard, foreground and background
python3 - "$B" "$T/../skills/hub/SKILL.md" > $R/jwait-forms.txt <<'PY'
import importlib.machinery, importlib.util, re, sys
loader = importlib.machinery.SourceFileLoader("hub_cli", sys.argv[1] + "/hub")
spec = importlib.util.spec_from_loader("hub_cli", loader); hub = importlib.util.module_from_spec(spec); loader.exec_module(hub)
forms = [hub.jwait_command("stage-a", "hub-17", None), hub.jwait_command("stage-a", "hub-17", __import__("datetime").datetime(2026, 1, 1, 14, 35))]
forms += [m for m in re.findall(r"`(jwait [^`]+)`", open(sys.argv[2], encoding="utf-8").read())]
print("\n".join(dict.fromkeys(forms)))
PY
n=$(wc -l < $R/jwait-forms.txt | tr -d ' '); [ "$n" -ge 4 ]; check $? 0 "jwait forms collected from the digest and the skill ($n)"
i=0; while IFS= read -r f; do i=$((i+1)); for bg in 0 1; do denied "$f" $bg; check $? 1 "jwait form $i passes the guard (background=$bg)"; done; done < $R/jwait-forms.txt
denied "until grep -q DONE journal.md; do sleep 20; done"; check $? 0 "jwait forms: positive control, a sleep loop is denied"
# …also with configured non-ASCII extra wake words resolved internally by --hub-events
echo '{"AGENT_HUB_JWAIT_MATCH": "WARTET AUF ANTWORT|RÉPONSE ATTENDUE|@hub (FRAGE|QUESTION)"}' > $R/config.json
f=$(python3 - "$B" <<'PY'
import datetime, importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hub_cli", sys.argv[1] + "/hub")
spec = importlib.util.spec_from_loader("hub_cli", loader); hub = importlib.util.module_from_spec(spec); loader.exec_module(hub)
print(hub.jwait_command("stage-a", "hub-17", datetime.datetime(2026, 1, 1, 14, 35)))
PY
)
case "$f" in *"--hub-events"*) check 0 0 "jwait form with extra words: the digest selects canonical hub events";; *) check 1 0 "jwait form lacks --hub-events ($f)";; esac
for bg in 0 1; do denied "$f" $bg; check $? 1 "jwait form with extra non-ASCII words passes the guard (background=$bg)"; done
rm $R/config.json

# ================================================================== context budget
TR=$R/transcript.jsonl
usage(){ python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","usage":{"input_tokens":int(sys.argv[1]),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}))' "$1" >> ${2:-$TR}; }
cb(){ python3 -c 'import json,sys; d={"hook_event_name":sys.argv[1],"session_id":"cb1","transcript_path":sys.argv[2],"tool_name":sys.argv[3],"tool_input":json.loads(sys.argv[4])}; print(json.dumps(d))' "$1" "$TR" "${2:-}" "${3:-null}" | python3 $HOOKS/context_budget.py; }
usage 100000
cb UserPromptSubmit > $R/cb0.out; check "$(wc -c < $R/cb0.out | tr -d ' ')" 0 "budget: below the warn threshold, silent"
usage 320000
cb UserPromptSubmit | grep -q 'Context budget: 320k'; check $? 0 "budget: warns on crossing 300k (default)"
cb PostToolUse Bash > $R/cb1.out; check "$(wc -c < $R/cb1.out | tr -d ' ')" 0 "budget: no second warning in the same step"
usage 352000
cb PostToolUse Bash > $R/cb1b.out; grep -q 'delamain:handoff' $R/cb1b.out; check $? 0 "budget: warns again a step later and points at delamain:handoff"
grep -qF '`agent-hub:handoff` in a session started before the rename' $R/cb1b.out; check $? 0 "budget: …and names the skill in its former form for a session started before the rename"  # rename:keep
cb PreToolUse Agent '{"prompt":"go"}' | grep -q '"deny"'; check $? 1 "budget: below the block threshold, Agent passes"
usage 510000
cb PreToolUse Agent '{"prompt":"go"}' > $R/cb1c.out; grep -q '"deny"' $R/cb1c.out; check $? 0 "budget: at 500k Agent is denied"
grep -qF 'delamain:handoff' $R/cb1c.out && grep -qF '`agent-hub:handoff` in a session started before the rename' $R/cb1c.out; check $? 0 "budget: the deny reason names the skill in both forms too"  # rename:keep
cb PreToolUse SendMessage '{"message":"go"}' | grep -q '"deny"'; check $? 0 "budget: SendMessage is denied"
cb PreToolUse Bash '{"command":"ls"}' | grep -q '"deny"'; check $? 1 "budget: Bash is not gated"
cb PreToolUse Agent '{"prompt":"take over from /x/HANDOFF-hub-a-2026.md"}' | grep -q '"deny"'; check $? 1 "budget: a handoff path passes"
cb PreToolUse SendMessage '{"message":"handoff-ok: wrap up"}' | grep -q '"deny"'; check $? 1 "budget: the handoff-ok marker passes"
echo '{"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":40000}}' >> $TR
cb PreToolUse Agent '{"prompt":"go"}' | grep -q '"deny"'; check $? 1 "budget: after a compact boundary the post-compact size counts"
usage 510000
cat > $R/config.json <<'EOF'
{"AGENT_HUB_CONTEXT_WARN": 600000, "AGENT_HUB_CONTEXT_BLOCK": 700000, "AGENT_HUB_CONTEXT_BLOCK_TOOLS": ["Bash"],
 "AGENT_HUB_CONTEXT_ESCAPE": "wrap-up-ok", "AGENT_HUB_CONTEXT_TODO": "Write the handoff now.", "AGENT_HUB_STATE_DIR": "@STATEPATH@"}
EOF
subst $R/config.json @STATEPATH@ "$R/state"
cb PreToolUse Agent '{"prompt":"go"}' | grep -q '"deny"'; check $? 1 "budget: own block threshold (700k) and tools (Agent no longer gated)"
usage 710000
cb PreToolUse Bash '{"command":"ls"}' | grep -q 'Write the handoff now'; check $? 0 "budget: own gated tool and own todo text"
cb PreToolUse Bash '{"command":"ls # wrap-up-ok"}' | grep -q '"deny"'; check $? 1 "budget: own escape pattern"
cb UserPromptSubmit > /dev/null; ls $R/state/context-budget/cb1.json > /dev/null 2>&1; check $? 0 "budget: state in the configured directory"
AGENT_HUB_CONTEXT_BLOCK_TOOLS="Read, SendMessage" cb PreToolUse SendMessage '{"message":"go"}' | grep -q '"deny"'; check $? 0 "budget: tools as a comma list from the environment"
echo '{"AGENT_HUB_CONTEXT_BUDGET": "off"}' > $R/config.json
cb PreToolUse SendMessage '{"message":"go"}' > $R/cb2.out; check "$(wc -c < $R/cb2.out | tr -d ' ')" 0 "budget: switched off"
rm $R/config.json
mkdir -p $R/cb1/subagents; usage 520000 $R/cb1/subagents/agent-a1.jsonl; echo '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5}}}' >> $TR
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"cb1","agent_id":"a1","transcript_path":sys.argv[1],"tool_name":"Agent","tool_input":{}}))' $TR | python3 $HOOKS/context_budget.py | grep -q '"deny"'; check $? 0 "budget: a subagent is measured by its own transcript"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"cb1","agent_id":"zz","transcript_path":sys.argv[1],"tool_name":"Agent","tool_input":{}}))' $TR | python3 $HOOKS/context_budget.py > $R/cb3.out; check "$(wc -c < $R/cb3.out | tr -d ' ')" 0 "budget: a subagent without a transcript stays silent"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"cb1","agent_id":"a1","transcript_path":sys.argv[1]}))' $TR | python3 $HOOKS/context_budget.py | grep -q 'Context budget: 520k'; check $? 0 "budget: a subagent is warned by its own size"
echo '{"AGENT_HUB_CONTEXT_ESCAPE": "(unclosed"}' > $R/config.json
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"cb1","agent_id":"a1","transcript_path":sys.argv[1],"tool_name":"Agent","tool_input":{"prompt":"handoff-ok"}}))' $TR | python3 $HOOKS/context_budget.py | grep -q '"deny"'; check $? 1 "budget: a broken escape regex falls back to the default (handoff-ok passes)"
rm $R/config.json
echo 'garbage' | python3 $HOOKS/context_budget.py > $R/cb4.out 2>&1; check "$?:$(wc -c < $R/cb4.out | tr -d ' ')" "0:0" "budget: broken input fails open"

# ================================================================== delegation dial and subagent rules
new_home; R=$AGENT_HUB_HOME; export HOME=$R/home; mkdir -p $HOME/.claude/agents $R/proj/.git
dg(){ python3 -c 'import json,sys; ti={k:v for k,v in (("subagent_type",sys.argv[2]),("model",sys.argv[3])) if v}; ti["prompt"]="x"; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"s1","cwd":sys.argv[4],"tool_name":sys.argv[1],"tool_input":ti}))' "$1" "${2:-}" "${3:-}" "${4:-$R/proj}" | python3 $HOOKS/delegation.py pre-tool; }
dden(){ dg "$@" | grep -q '"permissionDecision": "deny"'; }
ss(){ echo "{\"session_id\":\"$1\"}" | python3 $HOOKS/delegation.py ${2:-session-start}; }
ss s1 > $R/d0.out; check "$(wc -c < $R/d0.out | tr -d ' ')" 0 "dial off (default): nothing injected"
dden Agent general-purpose; check $? 1 "dial off, no rules: every Agent call passes"
CLAUDE_CODE_SESSION_ID=s1 $B/delegation show | grep -q 'dial is off'; check $? 0 "show says the dial is off"
# The plugin's name before the rename: a successor started by an older hub gets `/agent-hub:<skill> …` as plain text (the harness
# does not know that command). The hook adds a note, whether or not the dial is on. Names of the skills come from skills/.
fp(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":sys.argv[2],"prompt":sys.argv[1]}))' "$1" "${2:-$R/proj}" | python3 $HOOKS/delegation.py prompt; }  # rename:keep
SKILLS=$(cd "$T/../skills" && ls -d */ | tr -d /)
echo "$SKILLS" | grep -qx hub && echo "$SKILLS" | grep -qx status; check $? 0 "former name: the skills folder lists the real skills the tests below walk through"
for sk in $SKILLS; do
  fp "/agent-hub:$sk take over stage x from /y: run it" > $R/fn.out  # rename:keep
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["hookSpecificOutput"]; sk=sys.argv[2]; assert c["hookEventName"]=="UserPromptSubmit"; t=c["additionalContext"]; assert "former name" in t and "/agent-hub:"+sk in t and "`delamain:"+sk+"`" in t and "rest of the prompt as its arguments" in t and "`agent-hub:"+sk+"` in a session started before the rename" in t, t' $R/fn.out $sk  # rename:keep
  check $? 0 "former name, dial off: /agent-hub:$sk names the skill delamain:$sk"  # rename:keep
done
fp "  /agent-hub:status list the stages" | grep -q 'delamain:status'; check $? 0 "former name: leading whitespace is allowed"  # rename:keep
fp "/agent-hub:hub" | grep -q 'delamain:hub'; check $? 0 "former name: the bare command, no arguments"  # rename:keep
for neg in "/foo:hub take over stage x" "/agent-hub:no-such-skill take over" "/delamain:hub take over stage x" "/agent-hub:hubx foo" "/agent-hub: hub" "please run /agent-hub:hub" "how is it going?" ""; do  # rename:keep
  fp "$neg" > $R/fn2.out; check "$(wc -c < $R/fn2.out | tr -d ' ')" 0 "former name, negative: nothing for [$neg]"
done
echo '{"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":"/"}' | python3 $HOOKS/delegation.py prompt > $R/fn3.out; check "$?:$(wc -c < $R/fn3.out | tr -d ' ')" "0:0" "former name, negative: a hook input with no prompt"
echo '{"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":"/","prompt":["/agent-hub:hub"]}' | python3 $HOOKS/delegation.py prompt > $R/fn3.out; check "$?:$(wc -c < $R/fn3.out | tr -d ' ')" "0:0" "former name, negative: a prompt that is not a string"  # rename:keep
fp "/agent-hub:hub take over" | python3 -c 'import json,sys; json.load(sys.stdin)'; check $? 0 "former name: the output is one JSON document"  # rename:keep
# The owner asking for grilling: the hook names the companion skill, dial on or off (14.10: Russian free text did not load it)
for pos in "давай сразу грилинг по открытым вопросам" "ещё не следуют грилл ми" "погриль меня по плану" "Grill me on this design" "грильни" "/mattpocock-skills:grill-me план" "do some grilling on the plan"; do
  fp "$pos" > $R/gr.out
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["hookSpecificOutput"]; assert c["hookEventName"]=="UserPromptSubmit"; t=c["additionalContext"]; assert "mattpocock-skills:grilling" in t and "until the frontier" in t and "not a default taken on silence" in t and "hub grill --stage" in t' $R/gr.out
  check $? 0 "grilling: [$pos] names the grilling skill and its rounds"
done
for neg in "купил гриль на дачу" "гриль" "Сравни электрические грили" "Добавь grilled cheese в меню" "Проверь skills/grilling/SKILL.md" "how is it going?"; do
  fp "$neg" > $R/gr2.out; check "$(wc -c < $R/gr2.out | tr -d ' ')" 0 "grilling, negative: nothing for [$neg]"
done
# the skill names and the plugin's name are read from the plugin, not listed in the hook
FAKE=$R/fakeplug; mkdir -p $FAKE/skills/alpha $FAKE/.claude-plugin; ln -s "$T/../bin" $FAKE/bin; : > $FAKE/skills/alpha/SKILL.md
echo '{"name": "fakeplug"}' > $FAKE/.claude-plugin/plugin.json
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":"/","prompt":sys.argv[1]}))' "/agent-hub:alpha go" | PLUGIN_ROOT=$FAKE python3 $HOOKS/delegation.py prompt | grep -q 'skill `fakeplug:alpha`'; check $? 0 "former name: skill and plugin names come from the plugin root (a skill added there is covered)"  # rename:keep
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":"/","prompt":sys.argv[1]}))' "/agent-hub:hub go" | PLUGIN_ROOT=$FAKE python3 $HOOKS/delegation.py prompt > $R/fn4.out; check "$(wc -c < $R/fn4.out | tr -d ' ')" 0 "former name, negative: a skill the plugin root does not have gets nothing"  # rename:keep
echo '{"name": "agent-hub"}' > $FAKE/.claude-plugin/plugin.json  # rename:keep
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sf","cwd":"/","prompt":sys.argv[1]}))' "/agent-hub:alpha go" | PLUGIN_ROOT=$FAKE python3 $HOOKS/delegation.py prompt > $R/fn5.out; check "$(wc -c < $R/fn5.out | tr -d ' ')" 0 "former name, negative: a copy that still carries the former name has nothing to point to"  # rename:keep
echo '{"AGENT_HUB_DELEGATION": true}' > $R/config.json
ss s1 | grep -q 'Delegation level 3/5 (BALANCED)'; check $? 0 "dial on: level 3 by default, injected at session start"
ss s1 prompt > $R/d1.out; check "$(wc -c < $R/d1.out | tr -d ' ')" 0 "prompt: no re-injection while the level is unchanged"
ss s3 > /dev/null; $B/delegation set 1 --global > /dev/null; ss s3 prompt > $R/d2.out
grep -q 'Delegation level changed to 1' $R/d2.out && ! ss s3 prompt | grep -q .; check $? 0 "prompt: re-injected once after the level changed elsewhere"
rm $R/.state/delegation/level
fp "/agent-hub:hub take over stage x" > $R/fn6.out; python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]; assert t.startswith("Delegation level changed to 3. ") and t.rstrip().endswith("rest of the prompt as its arguments."), t; assert "`delamain:hub`" in t' $R/fn6.out; check $? 0 "former name, dial on: the note is appended to the level change in one injection"  # rename:keep
fp "/agent-hub:hub take over stage x" > $R/fn7.out; python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]; assert not t.startswith("Delegation level"), t; assert "`delamain:hub`" in t' $R/fn7.out; check $? 0 "former name, dial on: with the level unchanged only the note is injected"  # rename:keep
fp "how is it going?" > $R/fn8.out; check "$(wc -c < $R/fn8.out | tr -d ' ')" 0 "former name, dial on: a plain prompt injects nothing"
CLAUDE_CODE_SESSION_ID=s1 $B/delegation set 0 | grep -q 'Delegation level 0/5 (OFF)'; check $? 0 "set 0 for the session prints the new policy"
ss s1 prompt > $R/d2b.out; check "$(wc -c < $R/d2b.out | tr -d ' ')" 0 "prompt: no re-injection of what set already printed"
dden Agent general-purpose haiku; check $? 0 "level 0: Agent denied"
dden Workflow; check $? 0 "level 0: Workflow denied"
dg Agent | grep -q 'session override'; check $? 0 "level 0: the reason names where the level comes from"
python3 -c 'import json; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Agent","tool_input":{}}))' | python3 $HOOKS/delegation.py pre-tool | grep -q deny; check $? 1 "another session keeps the default level"
CLAUDE_CODE_SESSION_ID=s1 $B/delegation clear | grep -q 'effective level=3'; check $? 0 "clear: back to the default"
$B/delegation set 1 --global | grep -q 'effective level=1'; check $? 0 "set --global"
AGENT_HUB_DELEGATION_LEVEL=4 $B/delegation show | grep -q 'level=4 source=env'; check $? 0 "the environment level wins over the global one"
$B/delegation set 9 > /dev/null 2>&1; check $? 2 "usage: level out of range"
$B/delegation set 3 > /dev/null 2>&1; check $? 2 "usage: set without a session id and without --global"
# custom level texts and rules, from config.json
cat > $R/config.json <<'EOF'
{"AGENT_HUB_DELEGATION": "on", "AGENT_HUB_DELEGATION_DEFAULT": 2,
 "AGENT_HUB_DELEGATION_LEVELS": {"1": {"name": "SOLO", "policy": "Mostly alone."}}, "AGENT_HUB_DELEGATION_COMMON": "Common tail.",
 "AGENT_HUB_DELEGATION_RULES": [{"when": {"level": ["0", "1"], "tool": "Workflow"}, "decision": "deny", "reason": "No workflows at level {level}."}]}
EOF
$B/delegation show | grep -q 'Delegation level 1/5 (SOLO). Mostly alone. Common tail.'; check $? 0 "own level text and common tail"
dden Workflow; check $? 0 "own delegation rule: Workflow denied at level 1"
dden Agent general-purpose; check $? 1 "own delegation rule: Agent allowed at level 1 (the built-in level-0 rule is replaced)"
dg Workflow | grep -q 'No workflows at level 1'; check $? 0 "the reason is formatted with the call's fields"
rm -rf $R/.state; ss s9 | grep -q 'level 2/5'; check $? 0 "AGENT_HUB_DELEGATION_DEFAULT"
# the example policy (docs/examples/subagent-policy.json): effort rules apply with the dial off too
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["AGENT_HUB_DELEGATION"]="off"; json.dump(d, open(sys.argv[2],"w"))' $EXAMPLE $R/config.json
printf -- '---\nname: my-helper\neffort: medium\nmodel: opus\n---\nhi\n' > $HOME/.claude/agents/my-helper.md
printf -- '---\nname: lazy\n---\nhi\n' > $R/proj/.claude-agent.md; mkdir -p $R/proj/.claude/agents; mv $R/proj/.claude-agent.md $R/proj/.claude/agents/lazy.md
while IFS='|' read -r want tool typ model what; do
  dden "$tool" "$typ" "$model"; got=$([ $? = 0 ] && echo deny || echo allow)
  check "$got" "$want" "example policy: $what"
done <<'EOF'
allow|Agent|Explore|haiku|any type on haiku
deny|Agent|delamain:worker-low|haiku|haiku never at low
allow|Agent|delamain:worker-medium|haiku|haiku at medium
allow|Agent|delamain:worker-high|haiku|haiku at high
deny|Agent|fork|haiku|fork is always denied
deny|Agent|general-purpose|opus|unpinned definition inherits the session effort
deny|Agent||opus|no type = general-purpose
allow|Agent|delamain:worker-high|opus|plugin worker, explicit model
allow|Agent|delamain:worker-medium|opus|plugin worker at medium
deny|Agent|delamain:worker-high||plugin worker without a model inherits it
deny|Agent|delamain:worker-xhigh|opus|xhigh is not for non-Sonnet models
allow|Agent|delamain:worker-xhigh|sonnet|Sonnet at xhigh
allow|Agent|delamain:worker-high|sonnet|Sonnet at high
deny|Agent|delamain:worker-medium|sonnet|Sonnet never at medium
deny|Agent|delamain:worker-low|sonnet|Sonnet never at low
allow|Agent|worker-high|opus|plugin worker called without its prefix
allow|Agent|my-helper||user agent pinning effort and model
deny|Agent|lazy|opus|project agent without a pinned effort
allow|Workflow|||the example has no Workflow rule
EOF
dg Agent delamain:worker-medium sonnet | grep -q 'delamain:worker-medium at effort medium'; check $? 0 "example policy: the Sonnet reason names type and effort"
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"modle": "x"}, "decision": "deny"}]}' > $R/config.json
dg Agent general-purpose opus > $R/d3.out 2> $R/d3.err; check "$(wc -c < $R/d3.out | tr -d ' ')" 0 "malformed rules: fail-open, no decision"
grep -q "unknown field 'modle'" $R/d3.err; check $? 0 "malformed rules: reported on stderr"
echo '{"AGENT_HUB_EFFORT_RULES": [' > $R/config.json
dg Agent general-purpose opus > $R/d4.out 2>/dev/null; check "$?:$(wc -c < $R/d4.out | tr -d ' ')" "0:0" "broken config.json: fail-open"
echo 'not json' | python3 $HOOKS/delegation.py pre-tool > $R/d5.out 2>/dev/null; check "$?:$(wc -c < $R/d5.out | tr -d ' ')" "0:0" "broken hook input: fail-open"
mkdir -p $R/proj/.agent-hub $R/other/.git; cp $EXAMPLE $R/config.json
echo '{"AGENT_HUB_EFFORT_RULES": {"opus": "low"}}' > $R/proj/.agent-hub/config.json
dden Agent general-purpose opus $R/other; check $? 0 "effort rules: the hub home's apply in a repository without its own"
dden Agent general-purpose opus $R/proj; check $? 0 "effort rules: a repository's rules do not replace the user's (any deny wins)"
dg Agent delamain:worker-high opus $R/proj | grep -q 'opus runs only at effort low (got high, type delamain:worker-high). \[AGENT_HUB_EFFORT_RULES (proj/.agent-hub) rule 1\]'; check $? 0 "effort rules: the repository adds a restriction (shorthand), the set and rule are named"
dden Agent delamain:worker-high opus $R/other; check $? 1 "effort rules: …which does not apply outside it"
dden Agent delamain:worker-low opus $R/proj; check $? 1 "effort rules: shorthand allows the listed effort"
echo '{"AGENT_HUB_EFFORT_RULES": []}' > $R/proj/.agent-hub/config.json
dden Agent general-purpose opus $R/proj; check $? 0 "effort rules: an empty repository list does not switch the user's off"
dg Agent general-purpose opus $R/proj | grep -q 'AGENT_HUB_EFFORT_RULES (hub home) rule'; check $? 0 "effort rules: the user's deny names the hub home set"
dden Task general-purpose opus $R/other; check $? 0 "effort rules: the Task tool is checked like Agent"
$B/delegation try --cwd $R/other delamain:worker-high > $R/try1.out; check $? 1 "delegation try TYPE without a model: deny (model inherited), exit 1"
grep -q '"model_from": "inherit"' $R/try1.out; check $? 0 "delegation try: prints the call's fields"
$B/delegation try --cwd $R/other delamain:worker-high opus | grep -q '^allow'; check $? 0 "delegation try TYPE MODEL: allow"
rm $R/proj/.agent-hub/config.json

# the rename: a rule written with the plugin's former prefix applies to the same agent under the current name
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": "agent-hub:worker-high"}, "decision": "deny", "reason": "legacy rule"}]}' > $R/config.json  # rename:keep
dg Agent delamain:worker-high opus | grep -q 'legacy rule'; check $? 0 "rename: a rule for the former prefix denies delamain:worker-high"
dden Agent agent-hub:worker-high opus; check $? 0 "rename: …and an agent still called by the former prefix"  # rename:keep
dden Agent delamain:worker-low opus; check $? 1 "rename, negative: …not another agent of this plugin"
dden Agent foo:worker-high opus; check $? 1 "rename, negative: …not another plugin's worker-high"
dden Agent worker-high opus; check $? 1 "rename, negative: …nor the bare name (an exact rule stays exact)"
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": ["foo:*", "agent-hub:worker-*"]}, "decision": "deny", "reason": "legacy glob"}]}' > $R/config.json  # rename:keep
dden Agent delamain:worker-medium opus; check $? 0 "rename: a glob and a list with the former prefix match delamain:worker-medium"
dden Agent foo:anything opus; check $? 0 "rename: …and the other item of the list still matches"
dden Agent bar:worker-medium opus; check $? 1 "rename, negative: …and an unrelated prefix does not"
$B/delegation try --cwd $R/other agent-hub:worker-high opus | grep -q '"defined": "true"'; check $? 0 "rename: the definition of an agent called by the former prefix is found"  # rename:keep
$B/delegation try --cwd $R/other foo:worker-high opus | grep -q '"defined": "false"'; check $? 0 "rename, negative: …and of another plugin's agent is not"
# the rename, globs without the colon: a pattern for either name of this plugin matches both spellings of its agents
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": "agent-hub*"}, "decision": "deny", "reason": "legacy bare glob"}]}' > $R/config.json  # rename:keep
dden Agent delamain:worker-high opus; check $? 0 "rename: deny agent-hub* denies delamain:worker-high"  # rename:keep
dden Agent agent-hub:worker-high opus; check $? 0 "rename: deny agent-hub* denies agent-hub:worker-high"  # rename:keep
dden Agent foo:worker-high opus; check $? 1 "rename, negative: agent-hub* does not match foo:worker-high"  # rename:keep
dden Agent worker-high opus; check $? 1 "rename, negative: agent-hub* does not match the bare name worker-high"  # rename:keep
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": "delamain*"}, "decision": "deny", "reason": "current bare glob"}]}' > $R/config.json
dden Agent delamain:worker-high opus; check $? 0 "rename: deny delamain* denies delamain:worker-high"
dden Agent agent-hub:worker-high opus; check $? 0 "rename: deny delamain* denies a call still using agent-hub:worker-high"  # rename:keep
dden Agent foo:worker-high opus; check $? 1 "rename, negative: delamain* does not match foo:worker-high"
dden Agent worker-high opus; check $? 1 "rename, negative: delamain* does not match the bare name worker-high"
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": ["agent-hub*", "other-plugin:*"]}, "decision": "deny", "reason": "list"}]}' > $R/config.json  # rename:keep
dden Agent delamain:worker-low opus; check $? 0 "rename: a list with agent-hub* matches delamain:worker-low"  # rename:keep
dden Agent other-plugin:x opus; check $? 0 "rename: …and the other item of the list still matches"
dden Agent bar:worker-low opus; check $? 1 "rename, negative: …and an unrelated namespace does not"
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": "delamain:worker-low"}, "decision": "allow"}, {"when": {"subagent_type": "agent-hub*"}, "decision": "deny", "reason": "after the allow"}]}' > $R/config.json  # rename:keep
dden Agent delamain:worker-low opus; check $? 1 "rename, order: an allow rule placed before the deny still wins for delamain:worker-low"
dden Agent agent-hub:worker-low opus; check $? 1 "rename, order: …and for the same agent called by the former prefix"  # rename:keep
dden Agent delamain:worker-high opus; check $? 0 "rename, order: …while the deny applies to the other agents of the plugin"
echo '{"AGENT_HUB_EFFORT_RULES": [{"when": {"subagent_type": "agent-hub*"}, "decision": "deny", "reason": "first"}, {"when": {"subagent_type": "delamain:worker-low"}, "decision": "allow"}]}' > $R/config.json  # rename:keep
dden Agent delamain:worker-low opus; check $? 0 "rename, order: a deny placed before the allow wins"
echo '{"AGENT_HUB_DELEGATION": "on", "AGENT_HUB_DELEGATION_RULES": [{"when": {"subagent_type": "agent-hub*"}, "decision": "deny", "reason": "dial rule"}]}' > $R/config.json  # rename:keep
dg Agent delamain:worker-high | grep -q 'dial rule'; check $? 0 "rename: the same glob in AGENT_HUB_DELEGATION_RULES denies delamain:worker-high (one matching function)"
dden Agent foo:worker-high; check $? 1 "rename, negative: …and not foo:worker-high"
cp $EXAMPLE $R/config.json

# agent spawn applies AGENT_HUB_EFFORT_RULES (stand-in CLI; a denied spawn never starts)
export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py; W=$R/w; mkdir -p $W; echo "brief" > $W/b.md
$B/agent spawn --role s1 --cwd $W --model sonnet --effort medium --brief $W/b.md > $R/sp1.out 2>&1; check $? 2 "spawn: Sonnet at medium refused by the example rules"
grep -qi 'sonnet runs only at high or xhigh' $R/sp1.out; check $? 0 "spawn: …with the rule's reason"
[ ! -e $R/stage-a/agents/s1 ]; check $? 0 "spawn: nothing was started"
$B/agent spawn --role s2 --cwd $W --model sonnet --effort xhigh --brief $W/b.md > $R/sp2.out 2>&1; check $? 0 "spawn: Sonnet at xhigh allowed"
AGENT_HUB_MODEL_MAP=fast=claude-sonnet-x-y $B/agent spawn --role s3 --cwd $W --model fast --effort low --brief $W/b.md > $R/sp3.out 2>&1; check $? 2 "spawn: rules see the id an alias maps to"
$B/agent spawn --role s4 --cwd $W --model opus --effort xhigh --brief $W/b.md > $R/sp4.out 2>&1; check $? 0 "spawn: other models at any effort (the example only limits Sonnet for spawns)"
rm $R/config.json
$B/agent spawn --role s5 --cwd $W --model sonnet --effort low --brief $W/b.md > $R/sp5.out 2>&1; check $? 0 "spawn: no rules configured, nothing refused"
mkdir -p $W/.git $W/.agent-hub; echo '{"AGENT_HUB_EFFORT_RULES": {"sonnet": "high|xhigh"}}' > $W/.agent-hub/config.json
$B/agent spawn --role s6 --cwd $W --model sonnet --effort medium --brief $W/b.md > $R/sp6.out 2>&1; check $? 2 "spawn: the agent repository's shorthand refuses Sonnet at medium"
grep -q 'sonnet runs only at effort high or xhigh (got medium.*AGENT_HUB_EFFORT_RULES (w/.agent-hub) rule 1' $R/sp6.out; check $? 0 "spawn: …naming the rule"
$B/agent spawn --role s7 --cwd $W --model sonnet --effort high --brief $W/b.md > $R/sp7.out 2>&1; check $? 0 "spawn: …and accepts it at high"
for r in s2 s4 s5 s7; do $B/agent stop $r > /dev/null 2>&1; done

# ================================================================== plugin agents
for e in low medium high xhigh; do
  python3 - "$T/../agents/worker-$e.md" "$e" <<'PY'; check $? 0 "agents/worker-$e.md pins effort $e and no model"
import sys
text = open(sys.argv[1], encoding="utf-8").read().split("---")[1]
fm = dict(l.split(":", 1) for l in text.strip().splitlines())
assert fm["name"].strip() == "worker-" + sys.argv[2] and fm["effort"].strip() == sys.argv[2] and "model" not in fm
PY
done
exit $fail
