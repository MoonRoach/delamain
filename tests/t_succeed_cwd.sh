#!/bin/bash
# `hub succeed` starts the successor in a git worktree of the stage's project: the directory comes from the worktree the
# registered hub recorded at takeover (not from the hub shell's directory, which drifts), the budget hook names that one in
# the command it suggests, a directory outside git (or in another project) is refused, and a fall back to a headless hub is
# loud. Real git repositories in temp dirs; the CLI is tests/fake_claude_bg.py.
. "$(dirname "$0")/lib.sh"
unset AGENT_HUB_NO_PROJECT PLUGIN_ROOT CLAUDE_PLUGIN_ROOT FAKE_BG FAKE_LOGIN FAKE_LOGS FAKE_TRUSTED $(env | sed -n 's/^\(AGENT_HUB_\(CONTEXT\|AUTO\|SUCCESSOR\|STATE\)[A-Z_]*\)=.*/\1/p')
export CLAUDE_BIN=$T/fake_claude_bg.py CLAUDE_SESSIONS_DIR=$(mktemp -d) AGENT_HUB_SUCCESSOR_TIMEOUT=2 AGENT_HUB_AUTO_HANDOFF=on CLAUDE_EFFORT=high
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
new_home; R=$AGENT_HUB_HOME; export FAKE_BG_LOG=$R/bg.log
G=$(cd "$(mktemp -d)" && pwd -P); cd $G
git(){ command git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
HUB1=11111111-1111-4111-8111-111111111111
git init -q --bare rem.git; git clone -q rem.git proj 2>/dev/null
( cd proj && echo x > f && git add -A && git commit -qm init && git push -q origin main 2>/dev/null )
git init -q other; ( cd other && echo y > f && git add -A && git commit -qm init )
mkdir nogit
# the hub starts the way a hub does: MOVE to a worktree, re-run from there
( cd proj && $B/hub start --stage stage-a --session $HUB1 ) > $G/move.out 2>&1
WT=$G/proj/.claude/worktrees/stage-a-hub-1
( cd $WT && $B/hub start --stage stage-a --session $HUB1 ) > $G/start.out 2>&1; check $? 0 "setup: the hub started in its worktree"
H=$R/stage-a/coordinator/HANDOFF-hub-stage-a-2026-10-01-1200.md
printf '# Handoff "Hub stage-a #1" → "Hub stage-a #2" — stage-a\n\n## 0. First steps\n1. take over\n' > $H
H=$(cd "$(dirname $H)" && pwd -P)/$(basename $H)
bg(){ python3 - "$FAKE_BG_LOG" "$1" <<'PY'
import json, sys
try:
    calls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except FileNotFoundError:
    calls = []
calls = [c for c in calls if c["argv"] and c["argv"][0] == "--bg"]
print(len(calls) if sys.argv[2] == "count" else (calls[-1]["cwd"] if calls else "none"))
PY
}
state(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("pending") or {}).get(sys.argv[2]))' $R/stage-a/auto-handoff.json "$1" 2>/dev/null || echo none; }
reset(){ rm -f $FAKE_BG_LOG $R/stage-a/auto-handoff.json; }
J(){ cat "$(journal stage-a)" 2>/dev/null; }
succeed_in(){ local dir=$1; shift; ( cd "$dir" && $B/hub succeed --stage stage-a --handoff $H --model opus "$@" ); }

# ---- 1. takeover records the hub's worktree
python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1]))["roles"]["hub"]; assert os.path.realpath(d["worktree"])==os.path.realpath(sys.argv[2]), d' $R/stage-a/roles.json $WT
check $? 0 "takeover: roles.json records the hub's worktree"

# ---- 2. the shell drifted out of git (the incident): the registered worktree decides, the successor starts in the project
reset
succeed_in $G/nogit > $G/drift.out 2>&1; check $? 0 "drifted shell, no --cwd: exit 0"
check "$(bg cwd):$(state kind)" "$G/proj:bg" "drifted shell: --bg started from the project's main checkout, not from the shell's directory"
python3 -c 'import json,sys; assert "--worktree" in [c for c in map(json.loads, open(sys.argv[1])) if c["argv"][:1] == ["--bg"]][-1]["argv"]' $FAKE_BG_LOG; check $? 0 "drifted shell: in a worktree of its own (--worktree)"
J | grep -qF "registered worktree $WT"; check $? 0 "drifted shell: the journal line says the registered worktree was used"

# ---- 3. an explicit --cwd outside git is refused loudly: nothing started, nothing reserved
reset
succeed_in $WT --cwd $G/nogit > $G/nogit.out 2>&1; rc=$?
check "$rc:$(bg count):$(state kind)" "2:0:none" "--cwd outside git: refused (exit 2), no --bg, nothing reserved"
grep -q "is not inside a git repository" $G/nogit.out && grep -q "git worktree of its project" $G/nogit.out; check $? 0 "--cwd outside git: the message says why and what to do"
succeed_in $WT --cwd $G/other > $G/other.out 2>&1; rc=$?
check "$rc:$(bg count)" "2:0" "--cwd in another repository: refused"
grep -q "not in a worktree of the project of stage stage-a" $G/other.out; check $? 0 "--cwd in another repository: the message names the stage's project"
succeed_in $G/nogit --cwd $G/nogit --replace > $G/replace.out 2>&1; check "$?:$(bg count)" "2:0" "--replace with --cwd outside git: refused too"
succeed_in $G/nogit --cwd $WT --dry-run > $G/ok.out 2>&1; check "$?:$(bg count)" "0:0" "positive control: --cwd in the project's worktree passes (dry run)"

# ---- 4. no registered worktree (a hub registered before this release), shell outside git: refused, not started there
reset
python3 - $R/stage-a/roles.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["roles"]["hub"].pop("worktree"); json.dump(d, open(sys.argv[1], "w"))
PY
succeed_in $G/nogit > $G/legacy.out 2>&1; check "$?:$(bg count)" "2:0" "no registered worktree, shell outside git: refused"
succeed_in $WT --dry-run > /dev/null 2>&1; check $? 0 "…the shell inside the project's worktree still works"
python3 - $R/stage-a/roles.json $WT <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["roles"]["hub"]["worktree"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PY

# ---- 5. the budget hook names the registered worktree, whatever directory the hook input carries
TR=$R/tr.jsonl; python3 -c 'import json; print(json.dumps({"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":320000}}}))' > $TR
hook(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":sys.argv[1],"transcript_path":sys.argv[2],"cwd":sys.argv[3],"prompt":"","permission_mode":"acceptEdits","effort":{"level":"high"}}))' $HUB1 $TR "$1" | AGENT_HUB_STATE_DIR=$R/state$2 python3 $HOOKS/context_budget.py; }
hook $G/nogit a > $G/hook1.out
grep -qF -- "--cwd $WT" $G/hook1.out && ! grep -qF "$G/nogit" $G/hook1.out; check $? 0 "hook: the suggested command carries the registered worktree, not the drifted hook cwd"
python3 - $R/stage-a/roles.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["roles"]["hub"].pop("worktree"); json.dump(d, open(sys.argv[1], "w"))
PY
hook $G/nogit b > $G/hook2.out
grep -q 'Autopilot is on' $G/hook2.out && ! grep -qF -- "--cwd" $G/hook2.out; check $? 0 "hook, nothing registered and the hook cwd outside git: no --cwd suggested"
hook $WT c > $G/hook3.out; grep -qF -- "--cwd $WT" $G/hook3.out; check $? 0 "hook, nothing registered: a hook cwd that is a worktree of the project is kept"

# ---- 6. a stage without a project takes any directory
mkdir -p $R/stage-b/coordinator
( cd $G/nogit && $B/hub start --stage stage-b --session 22222222-2222-4222-8222-222222222222 --no-project ) > $G/np.out 2>&1; check $? 0 "setup: a no-project stage"
HB=$R/stage-b/coordinator/HANDOFF-hub-stage-b-2026-10-01-1200.md
printf '# Handoff "Hub stage-b #1" → "Hub stage-b #2" — stage-b\n\n## 0. First steps\n1. take over\n' > $HB
( cd $G/nogit && CLAUDE_CODE_SESSION_ID=22222222-2222-4222-8222-222222222222 $B/hub succeed --stage stage-b --handoff $HB --model opus --dry-run ) > $G/np2.out 2>&1
check $? 0 "--no-project stage: a directory outside git is accepted"

# ---- 7. a fall back to a headless hub is loud, in the output and in the journal
reset; export FAKE_BG=untrusted
python3 - $R/stage-a/roles.json $WT <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["roles"]["hub"]["worktree"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PY
succeed_in $WT > $G/loud.out 2>&1; check "$?:$(state kind)" "0:headless" "untrusted root: falls back to a headless hub"
grep -q "^auto-handoff: WARNING background successor not started — $G/proj is not trusted.*falling back to a headless hub.*NOT listed in Claude Desktop.*hub succeed --stage stage-a --replace --force" $G/loud.out; check $? 0 "fallback: the command's output is a warning with the reason and the fix"
J | grep -q "auto-handoff: WARNING background successor not started — $G/proj is not trusted.*NOT listed in Claude Desktop.*--replace --force"; check $? 0 "fallback: the journal line carries the same"
unset FAKE_BG
exit $fail
