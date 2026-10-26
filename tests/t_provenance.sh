#!/bin/bash
# Commit provenance (bin/provenance.py, bin/git-hooks/): an agent's commits carry Delamain-Stage/-Role/-Run trailers
# through the git hooks shim, the project's own hooks still run and still block, a person's commit stays untouched, and
# `hub why` walks back from a commit or a file:line to the run — or says it is guessing, or that it is not an agent's.
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE
export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=t@example.com
W=$(mktemp -d); R=$W/repo
git init -q -b main "$R"; echo 1 > "$R/f"; git -C "$R" add f
GIT_COMMITTER_DATE="$(( $(date +%s) - 7200 )) +0000" git -C "$R" commit -qm "initial"   # long before any agent of this script
OLD=$(git -C "$R" rev-parse HEAD)
printf '# Brief: provenance probe\n\nCommit a change.\n' > "$W/brief.md"
# the project's own pre-commit: leaves a mark, refuses while a file `block` exists
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\necho ran >> "%s/pre-commit.ran"\n[ ! -f block ]\n' "$W" > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
wait_dead(){ for i in $(seq 1 40); do $B/agent status "$1" | grep -q 'ALIVE' || return 0; sleep 0.25; done; }
run_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['runs'][-1]['id'])" "$AGENT_HUB_HOME/stage-a/agents/$1/meta.json"; }
trailer(){ git -C "$2" log -1 --format="%(trailers:key=Delamain-$1,valueonly)" "${3:-HEAD}" | sed '/^$/d'; }
spawn(){ local role=$1; shift; FAKE_SHELL="$1" $B/agent spawn --role "$role" --cwd "$R" --model sonnet --brief "$W/brief.md" "${@:2}" \
  > "$W/spawn-$role.out" 2>&1; check $? 0 "spawn $role"; wait_dead "$role"; }

# 1. an agent commit carries the trailers; the project's pre-commit ran under the shim
spawn writer 'echo 2 > f && echo w > w.txt && git add f w.txt && git commit -qm "agent change" && "$HUB_BIN/jlog" "PROGRESS committed"'
grep -q '^exit=0' "$R/shell.log"; check $? 0 "the agent's commit succeeded"
A1=$(git -C "$R" rev-parse HEAD)
check "$(trailer Stage "$R")" stage-a "trailer Delamain-Stage"
check "$(trailer Role "$R")" writer "trailer Delamain-Role"
check "$(trailer Run "$R")" "$(run_of writer)" "trailer Delamain-Run is the run id recorded in meta.json"
check "$(wc -l < "$W/pre-commit.ran" | tr -d ' ')" 1 "the project's pre-commit ran under the shim"
git -C "$R" log -1 --format=%B | grep -q "$HOME\|/Users/\|/home/"; check $? 1 "no path in the commit message"

# 2. control: the project's pre-commit that exits 1 still blocks the agent's commit (the shim chains its exit code)
rm -f "$R/shell.log"; touch "$R/block"
spawn blocked 'echo 3 > f && git add f && git commit -qm "must not land"'
grep -q '^exit=0' "$R/shell.log"; check $? 1 "a refusing project pre-commit blocks the agent's commit"
check "$(git -C "$R" rev-parse HEAD)" "$A1" "no commit was made"
rm -f "$R/block"; git -C "$R" checkout -q -- f

# 3. a person's commit in the same repository (no agent environment) has no trailers
echo h > "$R/h"; git -C "$R" add h; git -C "$R" commit -qm "human"
H=$(git -C "$R" rev-parse HEAD)
check "$(git -C "$R" log -1 --format='%(trailers:only)' | sed '/^$/d')" "" "a person's commit has no trailers"

# 4. a husky-style core.hooksPath keeps running under the shim; a person's commit cherry-picked by the agent stays theirs;
#    a commit in another repository gets no trailers
mkdir -p "$R/.husky/_"; printf '#!/bin/sh\necho husky >> "%s/husky.ran"\n' "$W" > "$R/.husky/_/pre-commit"
chmod +x "$R/.husky/_/pre-commit"; git -C "$R" config core.hooksPath .husky/_
git -C "$R" checkout -q -b side "$OLD"; echo s > "$R/s"; git -C "$R" add s; git -C "$R" commit -qm "side by a person"
S=$(git -C "$R" rev-parse HEAD); git -C "$R" checkout -q main; rm -f "$W/husky.ran"
git init -q -b main "$W/other"
spawn husky 'echo 4 > f && git add f && git commit -qm "under husky" && git cherry-pick '"$S"' && cd "'"$W/other"'" && echo o > o && git add o && git commit -qm other'
grep -q '^exit=0' "$R/shell.log"; check $? 0 "husky run: commits succeeded"
check "$(wc -l < "$W/husky.ran" | tr -d ' ')" 1 "the husky-style hooksPath pre-commit ran (cherry-pick runs none)"
check "$(trailer Role "$R" HEAD~1)" husky "a commit under husky-style hooksPath carries the trailers"
check "$(git -C "$R" log -1 --format='%(trailers:only)' | sed '/^$/d')" "" "a person's commit cherry-picked by the agent gets no trailers"
check "$(git -C "$W/other" log -1 --format='%(trailers:only)' | sed '/^$/d')" "" "a commit in another repository gets no trailers"
git -C "$R" config --unset core.hooksPath

# 5. hub why on a trailer commit: stage, role, run, brief, report, journal line; also as file:line and --json
out=$($B/hub why "$A1" --cwd "$R"); check $? 0 "hub why <sha> exit 0"
echo "$out" | grep -q "stage stage-a, role writer (tag writer), run $(run_of writer)"; check $? 0 "why: stage, role and run"
echo "$out" | grep -q "brief .*/brief.md"; check $? 0 "why: brief path"
echo "$out" | grep -q "report .*writer-REPORT.md"; check $? 0 "why: report path"
echo "$out" | grep -q "\[writer\] PROGRESS committed"; check $? 0 "why: the agent's journal line around the commit"
echo "$out" | grep -q "engine claude, model claude-sonnet-5-5 (asked for sonnet)"; check $? 0 "why: engine and model"
echo "$out" | grep -q "transcript .*not on this machine"; check $? 0 "why: a missing transcript is said, not invented"
check "$(echo "$out" | grep -c GUESS)" 0 "why: a trailer answer is not marked as a guess"
[ "$(echo "$out" | wc -l)" -le 40 ]; check $? 0 "why: at most 40 lines"
cd "$R" && $B/hub why w.txt:1 | grep -q "^w.txt:1 <- commit ${A1:0:12}"; check $? 0 "why <file>:<line> blames the line's commit"; cd - >/dev/null
$B/hub why "$A1" --cwd "$R" --json | python3 -c '
import json, sys
d = json.load(sys.stdin); a = d["agents"][0]
assert d["source"] == "trailers" and a["role"] == "writer" and a["stage"] == "stage-a" and a["brief"] and a["report"], d
assert any("PROGRESS committed" in l for l in a["journal"]), a'
check $? 0 "why --json: source, stage, role, brief, report, journal"

# 6. a trailer-less commit on an agent's branch (provenance off for that run): a guess, marked as one
rm -f "$R/shell.log"
AGENT_HUB_PROVENANCE=off FAKE_SHELL='echo g > g && git add g && git commit -qm "no trailers"' \
  $B/agent spawn --role guessed --cwd "$R" --worktree --model sonnet --brief "$W/brief.md" > "$W/spawn-guessed.out" 2>&1
check $? 0 "spawn guessed (worktree, provenance off)"; wait_dead guessed
G=$(git -C "$R" rev-parse agent/guessed)
check "$(git -C "$R" log -1 --format='%(trailers:only)' "$G" | sed '/^$/d')" "" "provenance off: no trailers"
out=$($B/hub why "$G" --cwd "$R")
echo "$out" | grep -q "^GUESS — no Delamain trailers; the .*reflog"; check $? 0 "why: a trailer-less agent commit is a marked guess"
echo "$out" | grep -q "stage stage-a, role guessed"; check $? 0 "why: the guess names the run"
cp /dev/null "$W/why-g.out"; echo "$out" > "$W/why-g.out"

# 7. an unrelated commit (a person's, before any agent): not an agent commit
$B/hub why "$OLD" --cwd "$R" | grep -q "not an agent commit"; check $? 0 "why: an unrelated commit is not an agent's"
$B/hub why "$H" --cwd "$R" > "$W/why-h.out"
grep -q "^WEAK GUESS\|not an agent commit" "$W/why-h.out"; check $? 0 "why: a person's commit next to an agent in a shared checkout is at most a weak guess"

# 9. a commit written in the editor gets the trailers from commit-msg (prepare-commit-msg saw an empty message)
rm -f "$R/shell.log"
spawn editor 'echo 6 > f && git add f && GIT_EDITOR="printf \"from the editor\n\" >" git commit -q'
grep -q '^exit=0' "$R/shell.log"; check $? 0 "editor run: the commit succeeded"
check "$(git -C "$R" log -1 --format=%s)" "from the editor" "editor run: the message is the editor's"
check "$(trailer Role "$R")" editor "a message written in the editor carries the trailers"

# 10. an agent of an older installation starts this one: its shim entry leaves the environment (no chain of two shims),
#     other inherited git parameters stay; and two shims in the chain never call each other forever
cp -R "$B/git-hooks" "$W/old-git-hooks"
rm -f "$R/shell.log"
GIT_CONFIG_PARAMETERS="'core.hooksPath=$W/old-git-hooks' 'maintenance.auto=false'" \
  spawn nested 'git config --get-all core.hooksPath; git config maintenance.auto'
check "$(grep -c git-hooks "$R/shell.log")" 1 "nested: one shim in the agent's core.hooksPath"
grep -q "^$B/git-hooks\$" "$R/shell.log"; check $? 0 "nested: it is this installation's"
grep -q '^false$' "$R/shell.log"; check $? 0 "nested: an inherited git parameter stays"
rm -f "$W/pre-commit.ran"; echo 7 > "$R/f"; git -C "$R" add f
GIT_CONFIG_PARAMETERS="'core.hooksPath=$W/old-git-hooks' 'core.hooksPath=$B/git-hooks'" bounded 30 git -C "$R" commit -qm "two shims"
check $? 0 "two shims in the chain: the commit finishes"
check "$(wc -l < "$W/pre-commit.ran" | tr -d ' ')" 1 "two shims in the chain: the project's pre-commit ran once"

# 11. run windows: a commit just after a resume belongs to the resumed run; a malformed meta.json breaks nothing
python3 - "$B" <<'PY2'
import sys, datetime as dt
sys.path.insert(0, sys.argv[1])
import hubcore as hc, provenance as pv
z = dt.timezone.utc
meta = {"_dir": "/nonexistent", "runs": [{"id": "a", "at": "2026-10-26T10:00:00+00:00"},
                                         {"id": "b", "at": "2026-10-26T11:00:00+00:00"}]}
got = pv.run_at(meta, dt.datetime(2026, 10, 26, 11, 2, tzinfo=z))
assert got and got["id"] == "b", got
assert pv.run_at(meta, dt.datetime(2026, 10, 26, 10, 30, tzinfo=z))["id"] == "a"
assert pv.run_at(meta, dt.datetime(2026, 10, 26, 9, 0, tzinfo=z)) is None
assert pv.run_windows({"_dir": "/x", "runs": 1}) == []
PY2
check $? 0 "run_at: the run going at the time, not the one before it; bad runs are no runs"
mkdir -p "$AGENT_HUB_HOME/stage-a/agents/broken"; echo '{"role": "broken", "runs": 1, "worktree": 3, "cwd": 5}' \
  > "$AGENT_HUB_HOME/stage-a/agents/broken/meta.json"
$B/hub why "$H" --cwd "$R" > /dev/null; check $? 0 "why: a malformed meta.json in the home breaks nothing"

# 8. Codex: the environment reaches the run's shell and the commit carries the trailers
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  FAKE_CODEX_SHELL='echo 5 > f && git add f && git commit -qm "codex change"' \
    $B/agent spawn --engine codex --role cx --cwd "$R" --model gpt-fixture --brief "$W/brief.md" > "$W/spawn-cx.out" 2>&1
  check $? 0 "spawn codex"; wait_dead cx
  grep -q '^exit=0' "$R/codex-shell.log"; check $? 0 "codex: the commit succeeded"
  check "$(trailer Role "$R")" cx "codex: the commit carries the trailers"
  check "$(trailer Run "$R")" "$(run_of cx)" "codex: the run id is the recorded one"
else
  echo "SKIP codex (Python < 3.11)"
fi
[ -n "${PROVENANCE_SHOW:-}" ] && cat "$W/why-g.out" "$W/why-h.out"
exit $fail
