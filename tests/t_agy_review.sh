#!/bin/bash
# bin/agy-review: the detached read-only review through the Antigravity CLI, its quota reader and its `check`.
# A stand-in `agy` (tests/fake_agy.py) answers from a scenario file; no model and no network are involved. The "owner"
# is a throw-away HOME with a sentinel ~/.gemini/antigravity-cli/settings.json that must come out untouched.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; export PYTHONDONTWRITEBYTECODE=1
P=$(mktemp -d); OWNER=$P/owner; CO=$P/checkout; EX=$P/extra; FA=$P/fa
mkdir -p $OWNER/.gemini/antigravity-cli $OWNER/Library $CO $EX $FA
echo '{"owner": "sentinel"}' > $OWNER/.gemini/antigravity-cli/settings.json
echo token > $OWNER/.gemini/oauth_creds.json
echo id > $OWNER/.gemini/antigravity-cli/installation_id
cp $OWNER/.gemini/antigravity-cli/settings.json $P/sentinel.copy
echo 'BRIEF-MARKER review the diff' > $P/brief.md
chmod +x $T/fake_agy.py
export HOME=$OWNER AGENT_HUB_AGY_BIN=$T/fake_agy.py FAKE_AGY_DIR=$FA
unset AGENT_HUB_AGY_REVIEW_MODEL AGENT_HUB_AGY_REVIEW_MIN_LEFT FAKE_AGY_PANEL FAKE_AGY_HANG
COREAL=$(cd $CO && pwd -P); EXREAL=$(cd $EX && pwd -P); RH=$R/agy-review-home

scn(){ printf '%s' "$1" > $FA/scenario.json; rm -f $FA/calls.jsonl; }
jf(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
call(){ python3 -c 'import json,sys; c=[json.loads(x) for x in open(sys.argv[1])][int(sys.argv[2])]; print(eval(sys.argv[3]))' $FA/calls.jsonl "$1" "$2"; }
ncalls(){ [ -f $FA/calls.jsonl ] && wc -l < $FA/calls.jsonl | tr -d ' ' || echo 0; }
# start a review and wait for its rc; RUN is the run dir. Returns run's exit code, 99 when rc never came.
waitrc(){ local i; for i in $(seq 1 ${2:-300}); do [ -e $1/rc ] && return 0; sleep 0.1; done; return 99; }
runit(){ $B/agy-review run --cwd $CO --brief $P/brief.md --name t "$@" > $P/run.out 2> $P/run.err; local rc=$?
  RUN=$(sed -n 's/^run: //p' $P/run.out); [ $rc = 0 ] || return $rc; waitrc $RUN; }
dry(){ $B/agy-review run --cwd $CO --brief $P/brief.md --name dry --dry-run "$@" > $P/dry.out 2> $P/dry.err; }
seed(){ python3 -c 'import json,sys,time; json.dump({"argon_weekly_remaining": float(sys.argv[1]), "gemini_weekly_remaining": 100.0, "seen_at": int(time.time()) - int(sys.argv[2])}, open(sys.argv[3], "w"))' "$1" "${2:-0}" $R/agy-limits.json; }
OK='{"conversation_id": "c1", "status": "SUCCESS", "response": "REVIEW TEXT: verdict merge", "duration_seconds": 4.5, "usage": {"input_tokens": 100, "output_tokens": 20, "thinking_tokens": 5, "cache_read_tokens": 7, "total_tokens": 132}}'

# ======== a normal run
scn "[{\"sleep\": 1, \"json\": $OK}]"
t0=$(date +%s); runit --add-dir $EX; rc=$?; t1=$(date +%s)
check $rc 0 "run: starts a review and it finishes"
grep -q "^run: $R/agy-runs/t-[0-9]\{8\}-[0-9]\{6\}$" $P/run.out && grep -q '^model: gemini-4-argon-high$' $P/run.out; check $? 0 "run prints the run dir under the hub home and the default model"
check "$(cat $RUN/rc)" 0 "rc is 0 when a review was produced"
check "$(wc -c < $RUN/rc | tr -d ' ')" 2 "rc is the digit and a newline, so jwait --file delivers it at once"
check "$(cat $RUN/final.md)" "REVIEW TEXT: verdict merge" "final.md is the review"
check "$(jf $RUN/usage.json 'd["attempts"]')-$(jf $RUN/usage.json 'd["conversation_id"]')-$(jf $RUN/usage.json 'd["usage"]["total_tokens"]')-$(jf $RUN/usage.json 'd["duration_seconds"]')" "1-c1-132-4.5" "usage.json: attempts, conversation, summed usage, duration"
check "$(jf $RUN/usage.json 'd["denied_actions"]')" "[]" "usage.json: denied actions (none here)"
[ -f $RUN/pid ] && [ -f $RUN/stderr.log ] && [ -f $RUN/out-0.json ]; check $? 0 "pid, stderr.log and out-0.json are there"
grep -q 'BRIEF-MARKER review the diff' $RUN/brief.md && grep -q 'Read-only (added by agy-review)' $RUN/brief.md; check $? 0 "brief.md is the brief plus the read-only footer"
check "$(jf $RUN/meta 'd["model"]')-$(jf $RUN/meta 'd["cwd"]' | sed "s|$COREAL|CO|")" "gemini-4-argon-high-CO" "meta records the model and the checkout"
# rc is written last: when it shows up, final.md and usage.json are already there, and they are older
scn "[{\"sleep\": 1, \"json\": $OK}]"
python3 -I - $B/agy-review $CO $P/brief.md > $P/order.out <<'PY'
import os, pathlib, subprocess, sys, time
b, co, brief = sys.argv[1:4]
out = subprocess.run([b, "run", "--cwd", co, "--brief", brief, "--name", "order"], capture_output=True, text=True).stdout
run = pathlib.Path([l[5:] for l in out.splitlines() if l.startswith("run: ")][0])
t_end = time.time() + 30
while not (run / "rc").exists() and time.time() < t_end:
    time.sleep(0.0002)
seen = [(run / n).exists() for n in ("final.md", "usage.json")]  # looked at the moment rc was first seen
m = [(run / n).stat().st_mtime_ns for n in ("final.md", "usage.json", "rc")]
print("rc-last" if all(seen) and m[0] <= m[1] <= m[2] else f"WRONG {seen} {m}")
PY
check "$(cat $P/order.out)" rc-last "rc appears last: final.md and usage.json exist when it does, and are not newer"
# detached: run returned while agy was still busy
scn "[{\"sleep\": 5, \"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name det > $P/det.out 2>&1
DET=$(sed -n 's/^run: //p' $P/det.out)
check "$([ -f $DET/pid ] && [ ! -e $DET/rc ] && echo detached)" detached "run returns while agy is still busy: the review goes on in the background"
waitrc $DET; check "$(cat $DET/rc)" 0 "…and finishes by itself"

# ======== what agy was called with
scn "[{\"json\": $OK}]"
runit --add-dir $EX; check "$(cat $RUN/rc)" 0 "second normal run"
check "$(call 0 '"--sandbox" in c["argv"]')" True "agy runs with --sandbox"
check "$(call 0 '"--dangerously-skip-permissions" in c["argv"]')" False "…never with --dangerously-skip-permissions"
check "$(grep -c 'dangerously' $FA/calls.jsonl)" 0 "…in any call"
check "$(call 0 'c["argv"][c["argv"].index("--model")+1]')" gemini-4-argon-high "--model is the default Argon"
check "$(call 0 'c["argv"][c["argv"].index("--output-format")+1]')-$(call 0 'c["argv"][c["argv"].index("--print-timeout")+1]')" json-45m "--output-format json, --print-timeout 45m"
check "$(call 0 'c["argv"][c["argv"].index("--add-dir")+1]' | sed "s|$EXREAL|EX|")" EX "--add-dir is passed through"
check "$(call 0 '"BRIEF-MARKER" in c["argv"][c["argv"].index("-p")+1] and "Read-only (added by agy-review)" in c["argv"][c["argv"].index("-p")+1]')" True "-p is the brief with the footer"
check "$(call 0 'c["home"]')" "$RH" "HOME passed to agy is the review home, not the owner's"
check "$(call 0 'c["cwd"]' | sed "s|$COREAL|CO|")" CO "agy runs in the checkout"
check "$(call 0 'sorted(json.loads(c["settings"])["trustedWorkspaces"])' | sed "s|$COREAL|CO|;s|$EXREAL|EX|")" "['CO', 'EX']" "the settings agy saw trust the checkout and the extra dir"
check "$(call 0 '"write_file(*)" in json.loads(c["settings"])["permissions"]["deny"] and "read_url(*)" in json.loads(c["settings"])["permissions"]["deny"] and "mcp(*)" in json.loads(c["settings"])["permissions"]["deny"]')" True "…deny write_file(*), read_url(*) and mcp(*)"
check "$(call 0 '[a for a in json.loads(c["settings"])["permissions"]["allow"] if a.startswith(("write_file", "read_url", "mcp"))]')" "[]" "…and allow no write, web or MCP tool"
check "$(call 0 '"command(git diff)" in json.loads(c["settings"])["permissions"]["allow"] and "command(git push)" in json.loads(c["settings"])["permissions"]["deny"] and "command(git push)" not in json.loads(c["settings"])["permissions"]["allow"]')" True "…allow reading git, deny pushing"
check "$(call 0 'set(json.loads(c["settings"])["permissions"]["allow"]) & set(json.loads(c["settings"])["permissions"]["deny"])')" "set()" "…no command is both allowed and denied"
check "$(call 0 'all(x in json.loads(c["settings"])["permissions"]["deny"] for x in ("command(python3)", "command(bash)", "command(curl)", "command(rm)", "command(less)", "command(vim)", "command(git -c)", "command(git submodule)", "command(git remote)"))')" True "…interpreters, shells, network clients, pagers, editors and git's program-starting forms are denied"
# commands that can start another program are denied EXPLICITLY (the model gets a refusal, the run goes on), and nothing
# that allows them by prefix is on the allow list: --sandbox leaves the network open, so the list is what keeps them out
check "$(call 0 'all(x in json.loads(c["settings"])["permissions"]["deny"] for x in ("command(awk)", "command(gawk)", "command(find)", "command(sed)", "command(rg)", "command(git grep)", "command(sort)", "command(xargs)"))')" True "awk, gawk, find, sed, rg, git grep, sort and xargs are in deny"
check "$(call 0 '[(a, x) for a in json.loads(c["settings"])["permissions"]["allow"] for x in ("awk", "gawk", "find", "sed", "rg", "git grep", "sort", "xargs", "less", "vim") if a.startswith("command(") and x.startswith(a[8:-1])]')" "[]" "…and no allow entry is a prefix of any of them"
check "$(call 0 'all(x in json.loads(c["settings"])["permissions"]["allow"] for x in ("command(grep)", "command(cat)", "command(head)", "command(tail)", "command(git diff)", "command(git log)", "command(git show)", "command(git blame)", "command(ls)", "command(wc)"))')" True "…while grep, cat, head, tail, ls, wc and the reading git forms are allowed"
# `printf -v PATH …` (bash/zsh) assigns a variable and the next allowed segment would run a repository executable: no command
# that assigns, exports, aliases or traps may be available, and none is allowed by a prefix
ENVCMDS='"printf", "export", "set", "unset", "alias", "typeset", "declare", "local", "read", "hash", "builtin", "command", "trap", "ulimit", "umask"'
check "$(call 0 'all("command(" + x + ")" in json.loads(c["settings"])["permissions"]["deny"] for x in ('"$ENVCMDS"'))')" True "printf and the environment builtins (export set unset alias typeset declare local read hash builtin command trap ulimit umask) are denied"
check "$(call 0 '[(a, x) for a in json.loads(c["settings"])["permissions"]["allow"] for x in ('"$ENVCMDS"') if a.startswith("command(") and (x == a[8:-1] or x.startswith(a[8:-1] + " "))]')" "[]" "…and no allow entry covers any of them (as a whole word: allowed \`tr\` is not \`trap\`, which is denied anyway)"
grep -q 'awk`, `find`, `sed`, `rg`, `sort`, `git grep`, `xargs`' $RUN/brief.md && grep -q 'grep -rn' $RUN/brief.md; check $? 0 "the footer of brief.md names grep -rn for searching and says awk, find, sed, rg, sort, git grep are refused"

# ======== the owner's own agy settings and sign-in
cmp -s $OWNER/.gemini/antigravity-cli/settings.json $P/sentinel.copy; check $? 0 "the owner's ~/.gemini/antigravity-cli/settings.json is untouched"
[ ! -L $RH/.gemini/antigravity-cli/settings.json ] && [ -f $RH/.gemini/antigravity-cli/settings.json ] && ! cmp -s $RH/.gemini/antigravity-cli/settings.json $P/sentinel.copy; check $? 0 "the review home has a settings.json of its own, not a link to the owner's"
check "$(readlink $RH/.gemini/oauth_creds.json)" "$OWNER/.gemini/oauth_creds.json" "the owner's sign-in file is linked into the review home"
check "$(readlink $RH/.gemini/antigravity-cli/installation_id)" "$OWNER/.gemini/antigravity-cli/installation_id" "…so is the installation id"
check "$(readlink $RH/Library)" "$OWNER/Library" "…and ~/Library (the macOS keychain)"
[ -e $RH/.gemini/projects.json ] || [ -L $RH/.gemini/projects.json ]; check $? 1 "negative: a file the owner does not have is not linked"
check "$(find $OWNER/Library -mindepth 1 | wc -l | tr -d ' ')" 0 "nothing was written through the Library link"
# rewritten on every run: a tampered settings.json is replaced
printf '{"permissions": {"allow": ["write_file(*)"]}}\n' > $RH/.gemini/antigravity-cli/settings.json
dry; check $? 0 "dry-run rebuilds the review home"
check "$(jf $RH/.gemini/antigravity-cli/settings.json '"write_file(*)" in d["permissions"]["deny"] and "write_file(*)" not in d["permissions"]["allow"]')" True "a tampered settings.json is rewritten on the next run"
# a link in place of settings.json is replaced, never written through
rm $RH/.gemini/antigravity-cli/settings.json; ln -s $OWNER/.gemini/antigravity-cli/settings.json $RH/.gemini/antigravity-cli/settings.json
dry; cmp -s $OWNER/.gemini/antigravity-cli/settings.json $P/sentinel.copy; check $? 0 "settings.json that is a link to the owner's is not written through"
[ ! -L $RH/.gemini/antigravity-cli/settings.json ]; check $? 0 "…the link is replaced by the tool's own file"
# links that point elsewhere, or were turned into copies (agy renames a new file over a state file), are made again
ln -sfn /nonexistent $RH/.gemini/oauth_creds.json; dry
check "$(readlink $RH/.gemini/oauth_creds.json)" "$OWNER/.gemini/oauth_creds.json" "a link that points elsewhere is made again"
rm $RH/.gemini/oauth_creds.json; echo copy > $RH/.gemini/oauth_creds.json; dry
check "$(readlink $RH/.gemini/oauth_creds.json)" "$OWNER/.gemini/oauth_creds.json" "a copy that replaced a link is replaced by the link"
check "$(cat $OWNER/.gemini/oauth_creds.json)" token "…and the owner's file keeps its content"

# ======== dry run
rm -rf $R/agy-runs; scn "[{\"json\": $OK}]"
dry; check $? 0 "dry-run: exit 0"
grep -q '^DRY-RUN: nothing started$' $P/dry.out && grep -q '^run: ' $P/dry.out; check $? 0 "…names the run and says nothing started"
D=$(sed -n 's/^run: //p' $P/dry.out)
[ -f $D/brief.md ] && [ -f $D/meta ] && [ ! -e $D/pid ] && [ ! -e $D/rc ]; check $? 0 "…brief.md and meta exist, pid and rc do not"
check "$(ncalls)" 0 "…agy was not called"

# ======== resumes
scn '[{"json": {"conversation_id": "c9", "status": "SUCCESS", "response": "", "denied_actions": [{"action": "python3 x.py", "display_name": "python3 x.py"}], "duration_seconds": 1.5, "usage": {"input_tokens": 10, "total_tokens": 10}}}, {"json": {"conversation_id": "c9", "status": "SUCCESS", "response": "ANSWER AFTER RESUME", "duration_seconds": 2, "usage": {"input_tokens": 20, "total_tokens": 25}}}]'
runit; check "$(cat $RUN/rc)" 0 "an empty answer with denied_actions is resumed, and the answer ends in rc 0"
check "$(cat $RUN/final.md)" "ANSWER AFTER RESUME" "…final.md is the answer of the second attempt"
check "$(ncalls)" 2 "…agy was called twice"
check "$(call 1 '"--conversation" in c["argv"] and c["argv"][c["argv"].index("--conversation")+1]')" c9 "…the second call resumes the conversation by id"
check "$(call 0 '"--conversation" in c["argv"]')" False "…the first call does not"
check "$(call 1 '"Continue the review" in c["argv"][c["argv"].index("-p")+1] and "BRIEF-MARKER" not in c["argv"][c["argv"].index("-p")+1]')" True "…with a nudge, not the brief again"
check "$(call 1 '"--sandbox" in c["argv"] and c["home"]')" "$RH" "…still sandboxed and under the review home"
check "$(jf $RUN/usage.json 'd["attempts"]')-$(jf $RUN/usage.json 'd["usage"]["input_tokens"]')-$(jf $RUN/usage.json 'd["usage"]["total_tokens"]')-$(jf $RUN/usage.json 'd["duration_seconds"]')-$(jf $RUN/usage.json 'len(d["denied_actions"])')" "2-30-35-3.5-1" "…usage.json sums both attempts and keeps the denied action"
scn '[{"json": {"conversation_id": "c9", "status": "SUCCESS", "response": "   ", "denied_actions": [{"action": "python3 x.py"}]}}]'
runit; check "$(cat $RUN/rc)" 2 "three empty attempts end in rc 2…"
check "$(ncalls)" 3 "…after exactly two resumes"
check "$(jf $RUN/usage.json 'd["attempts"]')" 3 "…usage.json says three attempts"
check "$(wc -c < $RUN/final.md | tr -d ' ')" 3 "…final.md holds what agy said (blank)"
scn '[{"json": {"status": "SUCCESS", "response": ""}}]'
runit; check "$(cat $RUN/rc)-$(ncalls)" "2-1" "an empty answer with no conversation id cannot be resumed: rc 2 after one call"

# ======== failures
scn '[{"exit": 7, "json": {"conversation_id": "c1", "status": "SUCCESS", "response": ""}}]'
runit; check "$(cat $RUN/rc)-$(ncalls)" "7-1" "agy's non-zero exit is the rc, and is not resumed"
scn '[{"json": {"conversation_id": "c1", "status": "ERROR", "error": "quota exceeded", "response": ""}}]'
runit; check "$(cat $RUN/rc)-$(ncalls)" "2-1" "status ERROR with exit 0: rc 2, not resumed"
grep -q 'quota exceeded' $RUN/stderr.log; check $? 0 "…the error is in stderr.log"
scn '[{"raw": "not json at all"}]'
runit; check "$(cat $RUN/rc)-$(ncalls)" "2-1" "output that is not JSON: rc 2"

# ======== SIGTERM: agy is stopped, the files and rc are still written
scn "[{\"sleep\": 30, \"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name term > $P/term.out 2>&1; TERM_RUN=$(sed -n 's/^run: //p' $P/term.out)
for i in $(seq 1 100); do [ "$(ncalls)" = 1 ] && break; sleep 0.1; done
FAKE_PID=$(call 0 'c["pid"]'); kill -TERM $(cat $TERM_RUN/pid)
waitrc $TERM_RUN; check "$(cat $TERM_RUN/rc 2>/dev/null)" 143 "SIGTERM to the worker: rc 143"
[ -f $TERM_RUN/final.md ] && [ -f $TERM_RUN/usage.json ]; check $? 0 "…final.md and usage.json are written"
sleep 0.3; kill -0 $FAKE_PID 2>/dev/null; check $? 1 "…and agy was stopped, not left running"
# an agy that ignores SIGTERM: the worker escalates to SIGKILL on agy's group after a grace period, and still ends with an rc
scn "[{\"sleep\": 60, \"ignore_term\": true, \"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name stubborn > $P/st.out 2>&1; ST_RUN=$(sed -n 's/^run: //p' $P/st.out)
for i in $(seq 1 100); do [ "$(ncalls)" = 1 ] && break; sleep 0.1; done
ST_PID=$(call 0 'c["pid"]'); kill -TERM $(cat $ST_RUN/pid)
waitrc $ST_RUN 900; check "$(cat $ST_RUN/rc 2>/dev/null)" 137 "SIGTERM that agy ignores: the worker ends with an rc (137, agy's group was killed) within a bounded time"
[ -f $ST_RUN/final.md ] && [ -f $ST_RUN/usage.json ]; check $? 0 "…final.md and usage.json are written"
sleep 0.3; kill -0 $ST_PID 2>/dev/null; check $? 1 "…and the stubborn agy is gone"
# a stop ends the run: no resume begins after it, even though the attempt that was running finished with an empty answer
scn "[{\"sleep\": 3, \"ignore_term\": true, \"json\": {\"conversation_id\": \"c9\", \"status\": \"SUCCESS\", \"response\": \"\"}}, {\"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name nostart > $P/ns.out 2>&1; NS_RUN=$(sed -n 's/^run: //p' $P/ns.out)
for i in $(seq 1 100); do [ "$(ncalls)" = 1 ] && break; sleep 0.1; done
kill -TERM $(cat $NS_RUN/pid); waitrc $NS_RUN 600
check "$(cat $NS_RUN/rc)-$(ncalls)-$(jf $NS_RUN/usage.json 'd["attempts"]')" "143-1-1" "a stop during an attempt that ends unanswered: rc 143 and no second attempt is started"

# ======== journal
rm -rf $R/s1; scn "[{\"json\": $OK}]"
runit --stage s1; check "$(cat $RUN/rc)" 0 "run --stage: finishes"
J=$(journal s1)
grep -q "^- [0-9:]* \[agy-review\] agy-review t started: model gemini-4-argon-high, run $RUN — wait for $RUN/rc$" $J; check $? 0 "a stage gets a start line…"
grep -q "^- [0-9:]* \[agy-review\] REVIEWED $RUN/final.md — rc 0$" $J; check $? 0 "…and, last, REVIEWED <run>/final.md — rc 0"
check "$(grep -c 'started' $J)-$(grep -c REVIEWED $J)" "1-1" "…one line each"
grep -v REVIEWED $J | grep -qE '\b(MERGED|STOP|DONE|BLOCKED|EXIT|QUESTION|ENDED|REVIEWED|GRILLED)\b'; check $? 1 "negative: the start line carries no status word that would wake the hub early"
HUB_TAG=hub-3 runit --stage s1; grep -q "^- [0-9:]* \[hub-3-agy\] REVIEWED $RUN/final.md — rc 0$" $J; check $? 0 "with a caller tag the lines are signed <tag>-agy (the hub's own jwait does not drop them)"
scn '[{"exit": 5, "json": {"conversation_id": "c1"}}]'
runit --stage s1; grep -q "^- [0-9:]* \[agy-review\] EXIT agy-review t: no review, rc 5 (agy failed) — see $RUN/stderr.log$" $J; check $? 0 "a run without a review journals EXIT, not REVIEWED"
HUB_STAGE=s2 runit; [ -f $(journal s2) ] && grep -q "started" $(journal s2); check $? 0 "the stage defaults to \$HUB_STAGE"
jsum(){ cat $(find $R -name 'journal-*.md' | sort) | cksum; }
j0=$(jsum); scn "[{\"json\": $OK}]"; runit; check "$(jsum)" "$j0" "negative: no stage, no journal line anywhere"
$B/agy-review run --cwd $CO --brief $P/brief.md --stage 'Bad Stage' > /dev/null 2>&1; check $? 2 "a bad stage name is a usage error"
# the contract of the skill: one jwait on the rc file
scn "[{\"sleep\": 2, \"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name jw > $P/jw.out 2>&1; JW=$(sed -n 's/^run: //p' $P/jw.out)
bounded 40 $B/jwait --file $JW/rc --for 30s --settle 1 --caller agy-test > $P/jw.wait 2>&1; check $? 0 "jwait --file <run>/rc returns when the review ends"
grep -q '^0$\|[[:space:]]0$' $P/jw.wait; check $? 0 "…and shows the rc"

# ======== the environment agy runs in: a fixed PATH, git pinned
mkdir -p $CO/bin $EX/tools $P/relpath-dir; ln -sfn $CO $P/colink
PYDIR=$(dirname "$(command -v python3)")
scn "[{\"json\": $OK}]"
PATH="relpath-dir:.::$CO/bin:$EX/tools:$P/colink/bin:$PATH" GIT_EXTERNAL_DIFF=/bin/true GIT_DIR=/nonexistent runit --add-dir $EX
check "$(cat $RUN/rc)" 0 "a run with a PATH holding ., an empty and a relative entry, and directories of the checkout and the extra dir"
cat > $P/pathcheck.py <<'PY'
import json, os, sys
env = json.loads(open(sys.argv[1]).readline())["env"]; meta = json.load(open(sys.argv[2]))
co, ex, pydir = (os.path.realpath(x) for x in sys.argv[3:6])
entries = env["PATH"].split(os.pathsep)
inside = [e for e in entries if any(os.path.commonpath([os.path.realpath(e), r]) == r for r in (co, ex))]
relative = [e for e in entries if not os.path.isabs(e)]
print("clean" if not inside and not relative and "" not in entries else f"BAD inside={inside} relative={relative}")
print("python-kept" if pydir in entries or os.path.realpath(pydir) in [os.path.realpath(e) for e in entries] else "PYTHON-LOST")
print("meta-same" if meta["path"] == env["PATH"] else f"META-DIFFERS {meta['path']!r} {env['PATH']!r}")
PY
python3 -I $P/pathcheck.py $FA/calls.jsonl $RUN/meta $COREAL $EXREAL $PYDIR > $P/path.out
check "$(sed -n 1p $P/path.out)" clean "the PATH agy got has no relative or empty entry and none inside the checkout or the extra dir (symlinks resolved)"
check "$(sed -n 2p $P/path.out)" python-kept "…the other absolute entries are kept (positive control)"
check "$(sed -n 3p $P/path.out)" meta-same "…and meta records that PATH"
check "$(call 0 '[c["env"].get(k) for k in ("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_NOSYSTEM")]')" "['1', 'safe.bareRepository', 'explicit', '1']" "the environment carries safe.bareRepository=explicit as command-scope config, and no system gitconfig"
check "$(call 0 '[k for k in c["env"] if k.startswith("GIT_") and not k.startswith("GIT_CONFIG_")]')" "[]" "…and inherited GIT_EXTERNAL_DIFF and GIT_DIR are dropped"
grep -q 'bareRepository = explicit' $RH/.gitconfig && [ ! -L $RH/.gitconfig ]; check $? 0 "the review HOME has a .gitconfig of its own with bareRepository = explicit"
printf '[core]\n\tfsmonitor = /bin/true\n' > $RH/.gitconfig; dry
grep -q 'bareRepository = explicit' $RH/.gitconfig && ! grep -q fsmonitor $RH/.gitconfig; check $? 0 "…rewritten on every run"
rm $RH/.gitconfig; ln -s $OWNER/.gemini/antigravity-cli/settings.json $RH/.gitconfig; dry
[ ! -L $RH/.gitconfig ] && cmp -s $OWNER/.gemini/antigravity-cli/settings.json $P/sentinel.copy; check $? 0 "…and a link in its place is replaced, not written through"
# functional: a tracked directory with a bare-repository layout whose config names a diff.external handler. An allowed `cd`
# into it and `git diff --no-index --ext-diff` would run the handler; the pinned git must not. (git needs 2.38 for the setting.)
GITV=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ -n "$GITV" ] && [ "${GITV% *}" -eq 2 ] && [ "${GITV#* }" -ge 38 ] || [ "${GITV% *}" -gt 2 ] 2>/dev/null; then
  GT=$P/gt; mkdir -p $GT/empty-home; (cd $GT && git init -q --bare fixture.git); echo readme > $GT/README.md
  printf '#!/bin/sh\ntouch %s/ext-diff-ran\nexit 0\n' $P > $GT/ext.sh; chmod +x $GT/ext.sh
  git config -f $GT/fixture.git/config diff.external $GT/ext.sh
  GP=$(call 0 'c["env"]["PATH"]')
  gitattack(){ rm -f $P/ext-diff-ran; (cd $GT/fixture.git && env -i PATH="$GP" "$@" git diff --no-index --ext-diff /dev/null ../README.md > /dev/null 2>&1); [ -e $P/ext-diff-ran ] && echo handler-ran || echo handler-not-run; }
  if [ "$(gitattack HOME=$GT/empty-home)" = handler-ran ]; then
    check handler-ran handler-ran "control: with no setting the handler of a bare-layout directory is run by an allowed git command"
    rm -f $RH/.gitconfig; dry   # whatever the tool writes into the review HOME, nothing left over from the checks above
    check "$(gitattack HOME=$RH)" handler-not-run "the review HOME's .gitconfig, as the tool writes it, alone stops it"
    check "$(gitattack HOME=$GT/empty-home GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=explicit GIT_CONFIG_NOSYSTEM=1)" handler-not-run "the GIT_CONFIG_* variables alone stop it too (HOME ignored)"
    check "$(gitattack HOME=$GT/empty-home $(call 0 '" ".join(k + "=" + v for k, v in c["env"].items() if k not in ("PATH", "HOME"))'))" handler-not-run "the GIT_* variables agy actually got, with no .gitconfig to help, stop it"
  else
    echo "SKIP functional git check: this git does not run the handler of a bare-layout directory without the setting"
  fi
else
  echo "SKIP functional git check: git 2.38 or newer is not available (found: ${GITV:-none})"
fi

# ======== ordering: `pid` and the start line are there before `rc` and REVIEWED can be
# the worker writes its own pid first thing: run it by hand on a prepared (dry-run) directory, where the parent never wrote one
scn "[{\"json\": $OK}]"; dry; D=$(sed -n 's/^run: //p' $P/dry.out); [ ! -e $D/pid ]
$B/agy-review _worker $D > /dev/null 2>&1; check "$([ "$(cat $D/pid)" = "$(call 0 'c["ppid"]')" ] && echo own-pid)-$(cat $D/rc)" "own-pid-0" "the worker writes its own pid (agy's parent) before agy runs, independently of the parent"
# the start line is written before the worker is started: with the journal locked, nothing starts; released, start precedes REVIEWED
rm -rf $R/s3; mkdir -p $R/s3/coordinator/work; scn "[{\"json\": $OK}]"; rm -rf $R/agy-runs
python3 -I - $B $R/s3/coordinator/work/.journal.lock $P/locked <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[2], "a"); fcntl.flock(fh, fcntl.LOCK_EX); open(sys.argv[3], "w").write("locked"); time.sleep(5)
PY
for i in $(seq 1 100); do [ -e $P/locked ] && break; sleep 0.1; done
$B/agy-review run --cwd $CO --brief $P/brief.md --name lock --stage s3 > $P/lk.out 2>&1 &
LK_PID=$!
sleep 3
LK_RUN=$(ls -d $R/agy-runs/lock-* 2>/dev/null | head -1)
check "$([ -n "$LK_RUN" ] && [ ! -e $LK_RUN/pid ] && [ "$(ncalls)" = 0 ] && echo nothing-started)" nothing-started "with the journal locked the start line cannot be written, and then no worker and no agy has started"
wait $LK_PID; waitrc $LK_RUN
check "$(cat $LK_RUN/rc)-$([ -f $LK_RUN/pid ] && echo pid)" "0-pid" "released: the run goes on, and pid is there when rc is"
J3=$(journal s3)
check "$(grep -n 'started' $J3 | head -1 | cut -d: -f1)-$(grep -n 'REVIEWED' $J3 | head -1 | cut -d: -f1)" "1-2" "…the start line precedes REVIEWED in the journal"
rm -f $P/locked
# the parent does not publish the pid: the worker does, after its signal handlers are in. So a SIGTERM sent the moment `pid`
# shows up is a stop (rc 143, journal line), not the death of a worker that was still starting
rm -rf $R/s4 $R/agy-runs; scn "[{\"sleep\": 20, \"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md --name early --stage s4 > $P/early.out 2>&1 &
EARLY_PID=$!
for i in $(seq 1 3000); do EP=$(cat $R/agy-runs/early-*/pid 2>/dev/null); [ -n "$EP" ] && break; sleep 0.005; done
kill -TERM $EP; EARLY_RUN=$(ls -d $R/agy-runs/early-* | head -1)
waitrc $EARLY_RUN 300; check "$(cat $EARLY_RUN/rc 2>/dev/null)" 143 "SIGTERM as soon as pid appears: the run still ends with an rc (143)"
[ -f $EARLY_RUN/final.md ] && [ -f $EARLY_RUN/usage.json ]; check $? 0 "…with final.md and usage.json"
wait $EARLY_PID; grep -q "EXIT agy-review early: no review, rc 143 (stopped by a signal) — see $EARLY_RUN/stderr.log" $(journal s4); check $? 0 "…and a journal end line"
grep -q "^pid: $EP$" $P/early.out; check $? 0 "run prints the pid it waited for"
sleep 0.3; kill -0 $(call 0 'c["pid"]' 2>/dev/null || echo 999999) 2>/dev/null; check $? 1 "…and no agy is left running"
# a worker that dies before it publishes its pid: run reports it, writes the rc and the journal line itself
rm -rf $P/bin-broken; cp -r $B $P/bin-broken
printf '\nimport sys as _s\nif len(_s.argv) > 1 and _s.argv[1] == "_worker":\n    raise SystemExit(7)\n' >> $P/bin-broken/hubcore.py
rm -rf $R/agy-runs; $P/bin-broken/agy-review run --cwd $CO --brief $P/brief.md --name broken --stage s5 > $P/br.out 2> $P/br.err; check $? 1 "a worker that exits before it publishes its pid: run exits 1"
BR_RUN=$(ls -d $R/agy-runs/broken-* | head -1)
check "$(cat $BR_RUN/rc 2>/dev/null)" 1 "…and has written the rc itself"
grep -q 'exited (7) before it began' $P/br.err && grep -q "EXIT agy-review broken: no review, rc 1 (the worker exited (7) before it began)" $(journal s5); check $? 0 "…said so, and journaled it"
rm -rf $P/bin-broken

# ======== refusals (exit 3) and usage errors (exit 2)
rm -f $R/agy-limits.json
AGENT_HUB_AGY_BIN=$P/no-such-agy $B/agy-review run --cwd $CO --brief $P/brief.md > $P/r.out 2> $P/r.err; check $? 3 "agy missing: exit 3"
grep -q 'agy is not on PATH' $P/r.err; check $? 0 "…with a one-line reason"
$B/agy-review run --cwd $P/no-checkout --brief $P/brief.md > /dev/null 2> $P/r.err; check $? 3 "checkout missing: exit 3"
$B/agy-review run --cwd $CO --brief $P/no-brief.md > /dev/null 2> $P/r.err; check $? 3 "brief missing: exit 3"
$B/agy-review run --cwd $CO --brief $P/brief.md --add-dir $P/no-dir > /dev/null 2> $P/r.err; check $? 3 "--add-dir missing: exit 3"
python3 -c 'print("x" * 500000)' > $P/big.md
$B/agy-review run --cwd $CO --brief $P/big.md > /dev/null 2> $P/r.err; check $? 3 "a brief too large for a command line: exit 3"
$B/agy-review run --cwd $CO > /dev/null 2>&1; check $? 2 "run without --brief: exit 2"
$B/agy-review run --cwd $CO --brief $P/brief.md --name 'a b' > /dev/null 2>&1; check $? 2 "a bad --name: exit 2"
$B/agy-review run --cwd $CO --brief $P/brief.md --model 'x;touch pwned' > /dev/null 2>&1; check $? 2 "a model id with shell syntax: exit 2"
$B/agy-review run --cwd $CO --brief $P/brief.md --min-left abc > /dev/null 2>&1; check $? 2 "--min-left abc: exit 2"
$B/agy-review run --cwd $CO --brief $P/brief.md --min-left 150 > /dev/null 2>&1; check $? 2 "--min-left 150: exit 2"
$B/agy-review frobnicate > /dev/null 2>&1; check $? 2 "an unknown subcommand: exit 2"
$B/agy-review --help | grep -q 'agy-review check'; check $? 0 "--help describes the tool"

# ======== model
dry; check "$(sed -n 's/^model: //p' $P/dry.out)" gemini-4-argon-high "model: the default"
dry --model gemini-4-argon-low; check "$(sed -n 's/^model: //p' $P/dry.out)" gemini-4-argon-low "model: --model"
AGENT_HUB_AGY_REVIEW_MODEL=gemini-4-argon-medium dry; check "$(sed -n 's/^model: //p' $P/dry.out)" gemini-4-argon-medium "model: AGENT_HUB_AGY_REVIEW_MODEL"
AGENT_HUB_AGY_REVIEW_MODEL=gemini-4-argon-medium dry --model other-1; check "$(sed -n 's/^model: //p' $P/dry.out)" other-1 "model: --model wins over the setting"
echo '{"AGENT_HUB_AGY_REVIEW_MODEL": "from-config"}' > $R/config.json; dry
check "$(sed -n 's/^model: //p' $P/dry.out)-$(grep -c 'not a setting' $P/dry.err)" "from-config-0" "model: the hub home's config.json sets it too"
rm $R/config.json

# ======== quota: a known low quota refuses, an unknown one does not
rm -rf $R/agy-runs; seed 5
dry; check $? 3 "quota 5 % < 20 %: exit 3"
grep -q 'below 20 %' $P/dry.err; check $? 0 "…with the reason"
check "$(ls $R/agy-runs 2>/dev/null | wc -l | tr -d ' ')" 0 "…no run directory was made"
seed 0; dry; check $? 3 "quota 0 % (a number, not 'unknown'): exit 3"
seed 100; dry; check $? 0 "positive control: quota 100 %: not refused"
seed 25; dry; check $? 0 "quota 25 % with the default floor 20: not refused"
seed 25; dry --min-left 30; check $? 3 "--min-left 30 refuses 25 %"
seed 25; AGENT_HUB_AGY_REVIEW_MIN_LEFT=30 dry; check $? 3 "AGENT_HUB_AGY_REVIEW_MIN_LEFT=30 refuses 25 %"
seed 25; echo '{"AGENT_HUB_AGY_REVIEW_MIN_LEFT": "30"}' > $R/config.json; dry; check $? 3 "…so does the hub home's config.json"; rm $R/config.json
seed 20; dry; check $? 0 "exactly the floor is enough"
seed 0; dry --min-left 0; check $? 0 "--min-left 0 switches the guard off"
seed 5 7200; dry; check $? 0 "a reading two hours old is unknown, not a refusal"
grep -q 'unknown' $P/dry.err; check $? 0 "…and the run says the quota is unknown"
rm -f $R/agy-limits.json; dry; check $? 0 "no reading at all (agy shows no panel): not a refusal"
echo 'garbage' > $R/agy-limits.json; dry; check $? 0 "an unreadable cache: not a refusal"
seed 5; scn "[{\"json\": $OK}]"
$B/agy-review run --cwd $CO --brief $P/brief.md > /dev/null 2>&1; check "$?-$(ncalls)" "3-0" "a refused run never calls agy"

# ======== check
seed 80; $B/agy-review check > $P/c.out 2>&1; check $? 0 "check: quota 80 %, exit 0"
seed 5; $B/agy-review check > $P/c.out 2>&1; check $? 1 "check: quota 5 %, exit 1"
grep -q 'below 20 %' $P/c.out; check $? 0 "…and says why"
seed 80; $B/agy-review check --min-left 90 > /dev/null 2>&1; check $? 1 "check --min-left 90 with 80 %: exit 1"
rm -f $R/agy-limits.json; $B/agy-review check > $P/c.out 2>&1; check $? 0 "check: quota unknown, exit 0"
AGENT_HUB_AGY_BIN=$P/no-such-agy $B/agy-review check > /dev/null 2>&1; check $? 1 "check: agy missing, exit 1"
seed 80; AGENT_HUB_AGY_BIN=$P/no-such-agy $B/agy-review check > /dev/null 2>&1; check $? 1 "check: agy missing beats a good cached reading"
$B/agy-review check --min-left x > /dev/null 2>&1; check $? 2 "check: a bad --min-left is a usage error"
rm -f $R/agy-limits.json
FAKE_AGY_HANG=1 bounded 30 $B/agy-review check > $P/c.out 2>&1; check $? 0 "check with an agy that hangs: unknown, exit 0"
# through the hub: the check of a reviewer entry
cat > $R/config.json <<EOF
{"AGENT_HUB_REVIEWERS": [{"name": "argon", "kind": "skill", "skill": "delamain:agy-review", "second": true, "check": "$B/agy-review check"},
 {"name": "agent", "kind": "agent"}]}
EOF
rm -f $R/agy-limits.json
(cd $P && FAKE_AGY_HANG=1 $B/hub reviewer --second --author claude --all) > $P/hub.hang 2>&1
grep -q 'argon (skill delamain:agy-review): available — check exited 0' $P/hub.hang; check $? 0 "an agy that hangs does not run the hub's 10 s check timeout out: the entry is available"
seed 5; (cd $P && $B/hub reviewer --second --author claude --json 2>/dev/null) > $P/hub.json; check "$?-$(jf $P/hub.json 'd["chosen"]')" "1-None" "as a reviewer entry's check: quota 5 % makes the entry unavailable"
seed 80; (cd $P && $B/hub reviewer --second --author claude --json 2>/dev/null) > $P/hub.json; check "$?-$(jf $P/hub.json 'd["chosen"]')" "0-argon" "…quota 80 % makes it the second opinion"
rm $R/config.json

# ======== the /usage panel parser, on panels written by hand from the shape agy draws
cat > $P/panel-untouched.txt <<'EOF'
 ╭──────────────────────────────────────────────────╮
 │ Usage (Google AI Pro)                             │
 │                                                  │
 │ GEMINI MODELS                                    │
 │ Weekly Limit Remaining                           │
 │ [ ████████████████████ ] 99.79%                  │
 │ Five Hour Limit Remaining                        │
 │ Quota available                                  │
 │                                                  │
 │ CLAUDE AND GPT MODELS                            │
 │ Weekly Limit Remaining                           │
 │ [ ██████████ ] 52.50%                            │
 │ Five Hour Limit Remaining                        │
 │ [ ████ ] 18.25%                                  │
 │                                                  │
 │ GEMINI 4 ARGON                                   │
 │ Gemini 4 Argon Weekly Limit                      │
 │ Quota available                                  │
 │ Within each group, models share the same quota.  │
 ╰──────────────────────────────────────────────────╯
EOF
# the same panel with the last "Quota available" (Argon's) replaced by a bar
python3 - $P/panel-untouched.txt $P/panel-used.txt <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.rfind("Quota available")
open(sys.argv[2], "w").write(t[:i] + "[ ████████████████ ] 84.12%" + t[i + len("Quota available"):])
PY
pj(){ $B/agy-review limits --json --from-file $1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["argon_weekly_remaining"], d["gemini_weekly_remaining"], d["gemini_5h_remaining"], d["claude_weekly_remaining"], d["claude_5h_remaining"], d["tier"])'; }
check "$(pj $P/panel-untouched.txt)" "100.0 99.79 100.0 52.5 18.25 Google AI Pro" "panel with Argon untouched ('Quota available' = 100 %), a bar and a missing bar in each other group"
check "$(pj $P/panel-used.txt)" "84.12 99.79 100.0 52.5 18.25 Google AI Pro" "panel with Argon at 84.12 %"
sed '/GEMINI 4 ARGON/,$d' $P/panel-used.txt > $P/panel-cut.txt
check "$(pj $P/panel-cut.txt | cut -d' ' -f1)" None "a panel cut before the Argon group: Argon is unknown, not 100"
printf ' GEMINI 4 ARGON\n Gemini 4 Argon Weekly Limit\n [ ] 0.00%%\n Within each group, models share quota\n' > $P/panel-zero.txt
check "$(pj $P/panel-zero.txt | cut -d' ' -f1)" 0.0 "Argon at 0 % is 0.0, not unknown"
$B/agy-review limits --from-file $P/panel-used.txt | grep -q 'Gemini 4 Argon, weekly: 84.12 % left'; check $? 0 "the text form names Argon's weekly quota"
$B/agy-review limits --from-file $P/no-such.txt > /dev/null 2>&1; check $? 1 "a panel file that cannot be read: exit 1"

# ======== the pty reader and its cache, against the stand-in's interactive mode
rm -f $R/agy-limits.json $FA/interactive.log; export FAKE_AGY_PANEL=$P/panel-used.txt
$B/agy-review limits --json > $P/l1.json 2> $P/l1.err; check $? 0 "limits: reads the panel through a pty (Esc, /usage, Enter)"
check "$(jf $P/l1.json 'd["argon_weekly_remaining"]')-$(jf $P/l1.json 'd["gemini_5h_remaining"]')-$(jf $P/l1.json 'd["claude_5h_remaining"]')" "84.12-100.0-18.25" "…and parses the colour-coded drawing"
check "$(jf $R/agy-limits.json 'd["argon_weekly_remaining"]')" 84.12 "…the answer is cached in the hub home"
$B/agy-review limits --json --max-age 600 > $P/l2.json; check "$(wc -l < $FA/interactive.log | tr -d ' ')" 1 "--max-age: a fresh cache is returned without starting agy"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["argon_weekly_remaining"]=11.5; json.dump(d, open(p,"w"))' $R/agy-limits.json
check "$($B/agy-review limits --json --max-age 600 | python3 -c 'import json,sys; print(json.load(sys.stdin)["argon_weekly_remaining"])')" 11.5 "…it is the cache that was returned"
seed 11.5 7200
check "$($B/agy-review limits --json --max-age 600 | python3 -c 'import json,sys; print(json.load(sys.stdin)["argon_weekly_remaining"])')-$(wc -l < $FA/interactive.log | tr -d ' ')" "84.12-2" "a stale cache is read again from agy"
$B/agy-review limits --json > /dev/null; check "$(wc -l < $FA/interactive.log | tr -d ' ')" 3 "without --max-age agy is always asked"
seed 40; check "$($B/agy-review check > /dev/null; echo $?)-$(wc -l < $FA/interactive.log | tr -d ' ')" "0-3" "check uses the cache (40 % left): agy is not started"
rm -f $R/agy-limits.json; dry; check "$?-$(jf $R/agy-limits.json 'd["argon_weekly_remaining"]')" "0-84.12" "run reads the quota from agy when nothing is cached, and caches it"
unset FAKE_AGY_PANEL; rm -f $R/agy-limits.json
$B/agy-review limits > /dev/null 2> $P/l3.err; check $? 1 "limits: an agy that draws no panel: exit 1"
grep -q 'panel was not read' $P/l3.err; check $? 0 "…and says so"
FAKE_AGY_PANEL=$P/panel-used.txt AGENT_HUB_HOME=$P/no-hub-yet $B/agy-review limits --json > /dev/null; check "$?-$([ -e $P/no-hub-yet ] && echo made || echo none)" "0-none" "a machine with no hub home is not given one by a quota read"

# ======== a relative AGENT_HUB_AGY_BIN is made absolute where it is resolved, never run from the checkout or the home
mkdir -p $P/relbin $CO/relbin $OWNER/relbin
printf '#!/bin/sh\nexec %s "$@"\n' $T/fake_agy.py > $P/relbin/agy-rel; chmod +x $P/relbin/agy-rel
for d in $CO $OWNER; do printf '#!/bin/sh\ntouch %s/decoy-ran\nexit 1\n' $P > $d/relbin/agy-rel; chmod +x $d/relbin/agy-rel; done
rm -f $P/decoy-ran; scn "[{\"json\": $OK}]"
(cd $P && AGENT_HUB_AGY_BIN=./relbin/agy-rel $B/agy-review run --cwd $CO --brief $P/brief.md --name rel > $P/rel.out 2>&1); REL_RUN=$(sed -n 's/^run: //p' $P/rel.out); waitrc $REL_RUN
check "$(cat $REL_RUN/rc)-$(ncalls)" "0-1" "AGENT_HUB_AGY_BIN=./relbin/agy-rel from another directory: the program it names ran (the review is done)"
check "$(jf $REL_RUN/meta 'd["agy"]')" "$(cd $P && pwd -P)/relbin/agy-rel" "…meta records its absolute path"
[ -e $P/decoy-ran ]; check $? 1 "…and the same relative path inside the checkout was not run"
export FAKE_AGY_PANEL=$P/panel-used.txt; rm -f $R/agy-limits.json
(cd $P && AGENT_HUB_AGY_BIN=./relbin/agy-rel $B/agy-review limits --json > $P/rel.json 2>&1); check "$(jf $P/rel.json 'd["argon_weekly_remaining"]')" 84.12 "the quota probe, which starts agy from the home directory, ran the right program too"
[ -e $P/decoy-ran ]; check $? 1 "…and not the relative path inside the home"
rm -f $R/agy-limits.json; (cd $P && AGENT_HUB_AGY_BIN=./relbin/agy-rel $B/agy-review check > /dev/null 2>&1); check "$?-$(jf $R/agy-limits.json 'd["argon_weekly_remaining"]')" "0-84.12" "…also for check"
unset FAKE_AGY_PANEL

# ======== the tool is a command of the plugin like the others
python3 - $B > $P/tools.out <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import hubcore as hc
print("listed" if "agy-review" in hc.plugin_tools() else "MISSING")
PY
check "$(cat $P/tools.out)" listed "agy-review is one of the plugin's tools (path_shadow sees it)"
exit $fail
