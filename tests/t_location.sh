#!/bin/bash
# hub start / hub takeover run only in a linked worktree of the project that has the project's .agent-hub/: a main clone on
# a feature branch, a directory outside git and a worktree without .agent-hub/ get a fresh worktree of origin's default
# branch and exit 4 with MOVE <path> — nothing registered, journaled or locked; the re-run from that path starts. A good
# place is fast-forwarded when it is clean and behind. Real git repositories with a bare "origin", all in temp dirs.
. "$(dirname "$0")/lib.sh"
unset AGENT_HUB_NO_PROJECT
new_home; export HUB_STAGE=; unset HUB_STAGE HUB_TAG; R=$AGENT_HUB_HOME
G=$(cd "$(mktemp -d)" && pwd -P); cd $G
git(){ command git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
S1=11111111-1111-4111-8111-111111111111
# origin with .agent-hub/ on main; two clones: `proj` stays the owner's main clone, `seed` pushes new commits
git init -q --bare rem.git; git clone -q rem.git seed 2>/dev/null
mkdir seed/.agent-hub; echo '{}' > seed/.agent-hub/config.json; echo x > seed/f
( cd seed && git add -A && git commit -qm init && git push -q origin main 2>/dev/null )
git clone -q rem.git proj 2>/dev/null
( cd proj && git checkout -qb feat/x && echo y > y && git add y && git commit -qm feature )   # the foreign feature branch
git clone -q rem.git plain-rem-seed 2>/dev/null; rm -rf plain-rem-seed
mkdir nogit
OUT(){ cat $G/last.out; }
run(){ ( cd "$1" && shift && "$@" ) > $G/last.out 2>&1; }                 # run <dir> <command…>; output in last.out
roles_hub(){ $B/roles --stage "$1" get hub 2>/dev/null; }
head_of(){ git -C "$1" rev-parse HEAD; }
origin_head(){ git -C $G/proj rev-parse origin/main; }

# ---- 1. the main clone on a feature branch: MOVE, nothing registered
run proj $B/hub start --stage s1 --session $S1
check $? 4 "start in the main clone on a feature branch → exit 4"
WT=$G/proj/.claude/worktrees/s1-hub-1
grep -qx "MOVE $WT" $G/last.out; check $? 0 "…MOVE <path>: <repo>/.claude/worktrees/<stage>-hub-<n>"
grep -q 'EnterWorktree with path='$WT $G/last.out && grep -q 'mcp__ccd_directory__change_directory' $G/last.out && grep -q 'Codex: run every later command with the workdir '$WT $G/last.out; check $? 0 "…says how to move: EnterWorktree, change_directory, Codex workdir"
grep -q "mcp__ccd_directory__change_directory with path=$G/proj — the main clone, not the worktree" $G/last.out && grep -q "call EnterWorktree with path=$WT, make no edits in the main clone" $G/last.out; check $? 0 "…a Desktop session under 'No folder' moves via the main clone, then EnterWorktree"
grep -q "^Then re-run: .*/hub start --stage s1 --session $S1\$" $G/last.out; check $? 0 "…and the command line to re-run"
check "$(head_of $WT)" "$(origin_head)" "…the worktree is on origin/main, not on the clone's feature branch"
[ "$(git -C $WT rev-parse --abbrev-ref HEAD)" = worktree-s1-hub-1 ] && [ -d $WT/.agent-hub ]; check $? 0 "…on its own branch, with .agent-hub/"
[ ! -e $R/s1/roles.json ] && [ ! -e $R/s1/coordinator ]; check $? 0 "…nothing registered or journaled (no roles.json, no work dir)"
[ -z "$(git -C $G/proj status --porcelain)" ]; check $? 0 "…the main clone shows no untracked .claude/worktrees"
run proj $B/hub start --stage s1 --session $S1 --dry-run; check $? 4 "dry run: the same verdict"
run proj $B/hub start --stage s1 --session $S1 --dry-run
[ "$(git -C $G/proj worktree list | wc -l | tr -d ' ')" = 2 ]; check $? 0 "…and it creates nothing (still one linked worktree)"

# ---- 2. the re-run from the MOVE path starts
run $WT $B/hub start --stage s1 --session $S1
check $? 0 "re-run from the MOVE path → starts"
grep -q '^DIGEST' $G/last.out && ! grep -q '^MOVE' $G/last.out; check $? 0 "…prints the digest, no MOVE"
case "$(roles_hub s1)" in $S1*) check 0 0 "…the hub is registered";; *) check "$(roles_hub s1)" "$S1" "…the hub is registered";; esac
python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1])); assert os.path.realpath(d["repo"])==os.path.realpath(sys.argv[2]), d' $R/s1/stage.json $G/proj; check $? 0 "…stage.json records the project (the main clone)"
run proj $B/hub start --stage s1 --session 22222222-2222-4222-8222-222222222222; check $? 2 "negative control: the stage already has another hub → the usual refusal (exit 2), not MOVE"

# ---- 3. outside git: a recorded stage project → MOVE; nothing recorded → NO PROJECT; --repo; --no-project
S2=22222222-2222-4222-8222-222222222222
run nogit $B/hub takeover --stage s1 --session $S2 --n 2
check $? 4 "takeover outside git with the stage's recorded project → exit 4"
WT2=$G/proj/.claude/worktrees/s1-hub-2
grep -qx "MOVE $WT2" $G/last.out; check $? 0 "…MOVE to a worktree of the recorded project (<stage>-hub-<n> with n = the hub number)"
case "$(roles_hub s1)" in $S1*) check 0 0 "…the registered hub is untouched";; *) check "$(roles_hub s1)" "$S1" "…the registered hub is untouched";; esac
mkdir -p $R/s3 $R/s4 $R/s5 $R/s6
run nogit $B/hub start --stage s3 --session $S1
check $? 4 "start outside git, nothing recorded → exit 4"
head -1 $G/last.out | grep -q '^NO PROJECT: .*/nogit is not inside a git repository and stage s3 has no recorded project'; check $? 0 "…NO PROJECT: …"
grep -q -- '--repo <main clone' $G/last.out && grep -q -- '--no-project' $G/last.out; check $? 0 "…names --repo and --no-project"
[ ! -e $R/s3/roles.json ]; check $? 0 "…nothing registered"
run nogit $B/hub start --stage s4 --session $S1 --repo $G/proj/.claude/worktrees/s1-hub-1/.agent-hub
check $? 4 "start outside git with --repo (any path inside the project) → exit 4"
grep -qx "MOVE $G/proj/.claude/worktrees/s4-hub-1" $G/last.out; check $? 0 "…MOVE to a worktree of that project's main clone (not of the worktree --repo pointed into)"
run nogit $B/hub start --stage s4 --session $S1 --repo $G/nogit; check $? 2 "negative: --repo outside git → usage error"
run nogit $B/hub start --stage s4 --session $S1 --repo $G/proj --no-project; check $? 2 "negative: --repo with --no-project → usage error"
run nogit $B/hub start --stage s5 --session $S1 --no-project
check $? 0 "start outside git with --no-project → starts in place"
grep -q '^DIGEST' $G/last.out && grep -q 'no project (--no-project): started in place' $(journal s5); check $? 0 "…and says so in the start line"
S5=55555555-5555-4555-8555-555555555555
run nogit $B/hub takeover --stage s5 --session $S5
check $? 0 "a later takeover of that stage outside git → in place (the stage is recorded as having no project)"
run nogit $B/hub start --stage s6 --session $S1 --dry-run; check $? 4 "negative control: the same without --no-project and with nothing recorded → exit 4"
AGENT_HUB_NO_PROJECT=1 run nogit $B/hub start --stage s6 --session $S1; check $? 0 "AGENT_HUB_NO_PROJECT=1 (scripted environments, the test suite) → in place"
grep -q 'no project' $(journal s6); check $? 1 "…silently"

# ---- 4. a linked worktree with .agent-hub/: starts; fast-forwarded when behind
git -C proj worktree add -q -b good $G/good origin/main
S7=77777777-7777-4777-8777-777777777777
mkdir -p $R/s7
run good $B/hub start --stage s7 --session $S7; check $? 0 "a linked worktree of origin/main with .agent-hub/ → starts"
grep -q 'refreshed' $G/last.out; check $? 1 "…up to date: nothing refreshed"
( cd seed && echo z > z && git add z && git commit -qm second && git push -q origin main 2>/dev/null )
git -C proj worktree add -q -b behind $G/behind origin/main       # origin/main of proj is behind seed's push until fetched
S8=88888888-8888-4888-8888-888888888888; mkdir -p $R/s8
run behind $B/hub start --stage s8 --session $S8; check $? 0 "a clean worktree behind origin/main → starts"
NEW=$(git -C seed rev-parse HEAD)
grep -q "^refreshed to origin/main ${NEW:0:7}\$" $G/last.out; check $? 0 "…prints 'refreshed to origin/main <sha>'"
check "$(head_of $G/behind)" "$NEW" "…and fast-forwarded to origin/main (fetched)"
( cd seed && echo w > w && git add w && git commit -qm third && git push -q origin main 2>/dev/null )
echo dirt > $G/behind/untracked.txt; S9=99999999-9999-4999-8999-999999999999; mkdir -p $R/s9
run behind $B/hub start --stage s9 --session $S9; check $? 0 "a dirty worktree behind origin/main → starts"
check "$(head_of $G/behind)" "$NEW" "…left alone (not fast-forwarded)"
rm $G/behind/untracked.txt; ( cd behind && echo mine > mine && git add mine && git commit -qm own )
S10=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; mkdir -p $R/s10
OWN=$(head_of $G/behind); run behind $B/hub takeover --stage s10 --session $S10 --n 1 --handoff /dev/null 2>/dev/null
mkdir -p $R/s11; S11=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
run behind $B/hub start --stage s11 --session $S11; check $? 0 "a worktree with its own commits → starts"
check "$(head_of $G/behind)" "$OWN" "…left alone (its own commits stay)"

# ---- a takeover records the project too: a later takeover from a folderless session finds it without --repo
mkdir -p $R/s20; S20=cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd
run good $B/hub takeover --stage s20 --session $S20 --n 1; check $? 0 "takeover in a good worktree"
python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1])); assert os.path.realpath(d["repo"])==os.path.realpath(sys.argv[2]), d' $R/s20/stage.json $G/proj; check $? 0 "…records the project in stage.json (the main clone)"
run nogit $B/hub takeover --stage s20 --session 12341234-1234-4234-8234-123412341234 --n 2
check $? 4 "the next takeover from a session without a folder (cwd outside git, no --repo) → exit 4"
grep -qx "MOVE $G/proj/.claude/worktrees/s20-hub-2" $G/last.out; check $? 0 "…MOVE into a fresh worktree of the recorded project"

# ---- relative --repo / --handoff: the printed re-run line holds absolute paths and works from the MOVE path
mkdir -p $R/s21 $R/s22 $G/h; echo '# Handoff "Hub s22 #1" → "Hub s22 #2"' > $G/h/HANDOFF.md
S21=21212121-2121-4212-8212-212121212121
( cd $G && $B/hub start --stage s21 --session $S21 --repo proj ) > $G/last.out 2>&1; check $? 4 "start from the parent directory with a relative --repo → exit 4"
RERUN=$(sed -n 's/^Then re-run: //p' $G/last.out)
case "$RERUN" in *"--repo $G/proj") check 0 0 "…the re-run line names --repo by its absolute path";; *) check "$RERUN" "… --repo $G/proj" "…the re-run line names --repo by its absolute path";; esac
( cd $G/proj/.claude/worktrees/s21-hub-1 && eval "$RERUN" ) > $G/last2.out 2>&1; check $? 0 "…and running it from the MOVE path starts the hub"
S22=22222222-2222-4222-8222-222222222223
( cd $G && $B/hub takeover --stage s22 --session $S22 --n 2 --repo proj --handoff h/HANDOFF.md ) > $G/last.out 2>&1; check $? 4 "takeover with a relative --handoff → exit 4"
RERUN=$(sed -n 's/^Then re-run: //p' $G/last.out)
case "$RERUN" in *"--handoff $G/h/HANDOFF.md"*) check 0 0 "…the re-run line names --handoff by its absolute path";; *) check "$RERUN" "… --handoff $G/h/HANDOFF.md" "…the re-run line names --handoff by its absolute path";; esac
( cd $G/proj/.claude/worktrees/s22-hub-2 && eval "$RERUN" ) > $G/last2.out 2>&1; check $? 0 "…and running it from the MOVE path takes the shift over"
( cd $G && $B/hub start --stage s21 --session $S21 --repo=proj --dry-run ) > $G/last.out 2>&1
grep -q -- "--repo=$G/proj" $G/last.out; check $? 0 "the --repo=PATH form is made absolute too"

# ---- --no-project replaces a recorded project: the latest choice wins
mkdir -p $R/s24; S24=24242424-2424-4242-8242-242424242424
run good $B/hub takeover --stage s24 --session $S24 --n 1; check $? 0 "a stage with a recorded project"
run nogit $B/hub takeover --stage s24 --session 25252525-2525-4252-8252-252525252525 --n 2 --no-project; check $? 0 "takeover with --no-project"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"no_project": True}, d' $R/s24/stage.json; check $? 0 "…stage.json holds no_project and no longer the old repo"
run nogit $B/hub takeover --stage s24 --session 26262626-2626-4262-8262-262626262626 --n 3; check $? 0 "the next folderless takeover starts in place (the old repo does not overrule the choice)"

# ---- 5. a linked worktree WITHOUT .agent-hub/ while origin/main has it → MOVE
git -C proj worktree add -q -b nocfg $G/nocfg origin/main
( cd nocfg && git rm -rqf .agent-hub && git commit -qm drop )
S12=cccccccc-cccc-4ccc-8ccc-cccccccccccc; mkdir -p $R/s12
run nocfg $B/hub start --stage s12 --session $S12
check $? 4 "a linked worktree without .agent-hub/ while origin/main has it → exit 4"
grep -qx "MOVE $G/proj/.claude/worktrees/s12-hub-1" $G/last.out && grep -q 'without .agent-hub/' $G/last.out; check $? 0 "…MOVE to a fresh worktree, saying why"
run $G/proj/.claude/worktrees/s12-hub-1 $B/hub start --stage s12 --session $S12; check $? 0 "…and the re-run from there starts"

# ---- 6. the path is reused when it is a clean worktree at origin/main, else the next suffix
S13=dddddddd-dddd-4ddd-8ddd-dddddddddddd; mkdir -p $R/s13
git -C proj fetch -q origin
run proj $B/hub start --stage s13 --session $S13; check $? 4 "the main clone again → MOVE"
grep -qx "MOVE $G/proj/.claude/worktrees/s13-hub-1" $G/last.out; check $? 0 "…first time: <stage>-hub-1"
run proj $B/hub start --stage s13 --session $S13
grep -qx "MOVE $G/proj/.claude/worktrees/s13-hub-1" $G/last.out && grep -q '^Reused the clean worktree' $G/last.out; check $? 0 "…second time: the same path is reused (clean, at origin/main)"
echo dirt > $G/proj/.claude/worktrees/s13-hub-1/dirt
run proj $B/hub start --stage s13 --session $S13
grep -qx "MOVE $G/proj/.claude/worktrees/s13-hub-1-2" $G/last.out; check $? 0 "…a dirty one is not reused: -2"
( cd seed && echo v > v && git add v && git commit -qm fourth && git push -q origin main 2>/dev/null )
run proj $B/hub start --stage s13 --session $S13
grep -qx "MOVE $G/proj/.claude/worktrees/s13-hub-1-3" $G/last.out; check $? 0 "…and when origin/main has moved on, the -2 worktree (older) is not reused either: -3"
check "$(head_of $G/proj/.claude/worktrees/s13-hub-1-3)" "$(git -C seed rev-parse HEAD)" "…the new one is on the fetched origin/main"

# ---- 7. fetch failing: the local ref is used, with a note; a repository without a remote
git clone -q rem.git offline 2>/dev/null; ( cd offline && git checkout -qb feat/o && git remote set-url origin $G/nonexistent.git )
mkdir -p $R/s14; S14=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
run offline $B/hub start --stage s14 --session $S14
check $? 4 "origin unreachable: still a MOVE"
grep -q '^ATTENTION: fetch of origin main failed' $G/last.out && grep -q 'using the local origin/main' $G/last.out; check $? 0 "…with a note that the local origin/main is used"
check "$(head_of $G/offline/.claude/worktrees/s14-hub-1)" "$(git -C offline rev-parse origin/main)" "…the worktree is on the local origin/main"
git init -q local; ( cd local && echo x > f && git add -A && git commit -qm init && git checkout -qb feat/l )
mkdir -p $R/s15; S15=ffffffff-ffff-4fff-8fff-ffffffffffff
run local $B/hub start --stage s15 --session $S15; check $? 4 "no remote: the main clone → MOVE"
check "$(git -C local rev-parse main)" "$(head_of $G/local/.claude/worktrees/s15-hub-1)" "…the worktree starts from the local main"
run $G/local/.claude/worktrees/s15-hub-1 $B/hub start --stage s15 --session $S15; check $? 0 "…and starts from there (no .agent-hub/ rule without a remote)"

git init -q empty; mkdir -p $R/s17
run empty $B/hub start --stage s17 --session 13131313-1313-4313-8313-131313131313
check $? 1 "a repository with no commits: no worktree is possible → a failure that asks for a first commit"
grep -q 'no commits yet — make a first commit' $G/last.out; check $? 0 "…says so"

# ---- 8. takeover goes through the same gate (--dry-run, a stage that exists)
mkdir -p $R/s16; S16=12121212-1212-4212-8212-121212121212
run proj $B/hub takeover --stage s16 --session $S16 --n 1 --dry-run; check $? 4 "takeover in the main clone on a feature branch → exit 4"
grep -q '^\[plan\] would create' $G/last.out; check $? 0 "…a dry run says what it would create"
exit $fail
