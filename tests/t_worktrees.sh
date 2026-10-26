#!/bin/bash
# agent worktrees: the ledger of a repository's worktrees and `--prune`. A throw-away repository with a bare "remote", a
# stub `gh` on PATH for squash-merged branches, a stand-in CLI for live agents. A worktree goes only when it is merged,
# clean, fully pushed, not in use (and, where use is unknown, idle for long enough); each safety rule has a control that
# fails if the rule is dropped: the worktree survives --prune, and goes once the condition is fixed.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
P=$(mktemp -d); REMOTE=$P/remote.git; REPO=$P/app; STUB=$P/stub; GHDIR=$P/gh; mkdir -p $STUB $GHDIR
G(){ git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
echo "brief: do the thing" > $P/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
git init -q --bare -b main $REMOTE
git init -q -b main $REPO; G -C $REPO commit -q --allow-empty -m init
git -C $REPO remote add origin $REMOTE; git -C $REPO push -q -u origin main 2>/dev/null
printf '*.log\n' >> $REPO/.git/info/exclude        # the stand-in CLI writes its logs into the agent's directory
# a stub gh: `gh pr list --state merged --head BRANCH --json …` answers from $GHDIR/<branch, / as _>.json (running
# <branch>.hook first, once); GH_STUB_FAIL=1 fails
cat > $STUB/gh <<'EOF'
#!/bin/bash
[ -n "${GH_STUB_FAIL:-}" ] && { echo "gh: not logged in; run gh auth login" >&2; exit 4; }
[ "$1 $2" = "pr list" ] || exit 2
while [ $# -gt 0 ]; do [ "$1" = --head ] && head=$2; shift; done
f="$GH_STUB_DIR/$(echo "$head" | tr / _).json"; h="${f%.json}.hook"
[ -f "$h" ] && { bash "$h"; rm -f "$h"; }   # <branch>.hook: something that happens while the ledger is built, once
[ -f "$f" ] && cat "$f" || echo '[]'
EOF
chmod +x $STUB/gh; export GH_STUB_DIR=$GHDIR
WT=$REPO/.worktrees
# add_wt NAME [BASE]: a worktree on a new branch NAME from origin/main (or BASE)
add_wt(){ git -C $REPO worktree add -q -b $1 $WT/$1 ${2:-origin/main}; }
# commit_in NAME FILE: a commit in the worktree
commit_in(){ echo "$2" > $WT/$1/$2; G -C $WT/$1 add $2; G -C $WT/$1 commit -q -m "add $2"; }
# merge_into_main BRANCH: push it, then fast-forward main and push main (a merged-by-ancestry branch)
merge_into_main(){ git -C $REPO push -q origin $1 2>/dev/null; G -C $REPO merge -q --ff-only $1; git -C $REPO push -q origin main 2>/dev/null; }
LISTING(){ (cd $P && PATH=$STUB:$PATH $B/agent worktrees --repo $REPO "$@"); }
listed(){ git -C $REPO worktree list --porcelain | grep -c "^worktree "; }
branch_exists(){ git -C $REPO rev-parse --verify -q refs/heads/$1 > /dev/null; }
# wfield JSONFILE PATH-SUFFIX KEY: the value of KEY for the worktree whose path ends with the suffix
wfield(){ python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
w = [x for x in d["worktrees"] if x["path"].endswith(sys.argv[2])]
print(json.dumps(w[0][sys.argv[3]]) if w else "MISSING")
PY
}

# ---- 1. merged and clean: removed, and its branch with it
add_wt feat/merged; commit_in feat/merged m.txt; merge_into_main feat/merged
add_wt feat/dirty; commit_in feat/dirty d.txt; merge_into_main feat/dirty; echo scratch > $WT/feat/dirty/untracked.txt
LISTING --json --idle-for 0s > $P/l1.json 2> $P/l1.err; check $? 0 "the listing works (--json)"
check "$(wfield $P/l1.json /.worktrees/feat/merged merged_by)" '"ancestry"' "feat/merged: merged by ancestry"
check "$(wfield $P/l1.json /.worktrees/feat/merged removable)" "true" "…and removable (merged, clean, pushed, nobody there)"
check "$(wfield $P/l1.json /.worktrees/feat/dirty dirty_files)" "1" "feat/dirty: one changed file (an untracked file counts)"
before=$(listed)
LISTING --prune --dry-run --idle-for 0s > $P/dry.out 2>&1; check $? 0 "--prune --dry-run"
grep -q 'would remove' $P/dry.out && grep -q 'feat/merged' $P/dry.out; check $? 0 "…says what it would remove"
[ "$(listed)" = "$before" ] && [ -d $WT/feat/merged ] && branch_exists feat/merged; check $? 0 "…and removes nothing (worktrees and branch still there)"
LISTING --prune --idle-for 0s > $P/p1.out 2>&1; check $? 0 "--prune"
[ ! -e $WT/feat/merged ]; check $? 0 "the merged, clean worktree is gone"
! branch_exists feat/merged; check $? 0 "…with its branch (merged by ancestry)"
[ -d $WT/feat/dirty ] && [ -f $WT/feat/dirty/untracked.txt ]; check $? 0 "control: the dirty worktree survives --prune, its file intact"
grep -q 'dirty: 1 changed file' $P/p1.out; check $? 0 "…and the output says why"
grep -q 'removed 1, kept 1 (dirty 1)' $P/p1.out; check $? 0 "the summary counts removed and kept by reason"
[ -d $REPO/.git ] && [ -f $REPO/.git/HEAD ] && git -C $REPO rev-parse HEAD > /dev/null; check $? 0 "the main checkout is never touched"
grep -Fq 'main checkout' $P/p1.out || LISTING | grep -Fq 'main checkout'; check $? 0 "…and is listed as the main checkout"
rm $WT/feat/dirty/untracked.txt
LISTING --prune --idle-for 0s > $P/p1b.out 2>&1; [ ! -e $WT/feat/dirty ]; check $? 0 "positive control: cleaned, the same worktree goes"

# ---- 2. unpushed work is never removed
add_wt feat/ahead; commit_in feat/ahead a.txt
LISTING --json > $P/l2.json 2>&1
check "$(wfield $P/l2.json /.worktrees/feat/ahead unpushed_commits)" "1" "feat/ahead: one commit on no remote"
LISTING --prune --idle-for 0s > $P/p2.out 2>&1; [ -d $WT/feat/ahead ] && branch_exists feat/ahead; check $? 0 "an unpushed commit: worktree and branch survive --prune"
grep -q '1 commit on no remote' $P/p2.out; check $? 0 "…the output names the commit"
# pushed but not merged: kept for the other reason
git -C $REPO push -q origin feat/ahead 2>/dev/null
LISTING --prune --idle-for 0s > $P/p2b.out 2>&1; [ -d $WT/feat/ahead ]; check $? 0 "pushed but not merged: kept"
grep -q 'branch not merged into origin/main' $P/p2b.out; check $? 0 "…saying it is not merged"
merge_into_main feat/ahead
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/feat/ahead ]; check $? 0 "positive control: once merged it goes"

# ---- 3. a live agent keeps its worktree; after it stops the worktree goes
FAKE_HOLD=30 $B/agent spawn --role liver --cwd $REPO --model haiku --brief $P/b.md --worktree feat/live > $P/spawn.out 2>&1; check $? 0 "an agent spawned in its own worktree"
LISTING --json > $P/l3.json 2>&1
check "$(wfield $P/l3.json /.worktrees/feat/live kind)" '"agent"' "attributed to the agent run"
check "$(wfield $P/l3.json /.worktrees/feat/live who)" '"agent liver (stage stage-a)"' "…by role and stage"
check "$(wfield $P/l3.json /.worktrees/feat/live live)" '"yes"' "…and live"
LISTING --prune --idle-for 0s > $P/p3.out 2>&1; [ -d $WT/feat/live ]; check $? 0 "a live agent: the worktree survives --prune (even with --idle-for 0s)"
grep -q 'in use: agent liver' $P/p3.out; check $? 0 "…the output names the agent"
$B/agent stop liver > /dev/null 2>&1
LISTING --prune --idle-for 0s > $P/p3b.out 2>&1; [ ! -e $WT/feat/live ]; check $? 0 "positive control: stopped, merged (it never left origin/main), clean: removed"

# ---- 4. squash-merged: no ancestry, the merged pull request (gh) decides
sq(){  # sq NAME: a branch pushed, then squash-merged by hand and its remote branch deleted
  add_wt $1; commit_in $1 $1.txt; git -C $REPO push -q origin $1 2>/dev/null
  echo "$1" > $REPO/sq-$1.txt; G -C $REPO add sq-$1.txt; G -C $REPO commit -q -m "squash $1 (#7)"; git -C $REPO push -q origin main 2>/dev/null
  git -C $REPO push -q origin --delete $1 2>/dev/null; git -C $REPO fetch -q --prune origin
}
pr_json(){ printf '[{"number":%s,"url":"https://example.test/pr/%s","headRefOid":"%s","baseRefName":"%s","mergedAt":"2026-10-26T00:00:00Z"}]\n' "$2" "$2" "$3" "${4:-main}" > $GHDIR/$(echo $1 | tr / _).json; }
sq squash1; pr_json squash1 7 "$(git -C $WT/squash1 rev-parse HEAD)"
sq squash2; pr_json squash2 8 "$(git -C $WT/squash2 rev-parse HEAD)"
sq squash3; pr_json squash3 9 "$(git -C $WT/squash3 rev-parse HEAD)"; commit_in squash3 later.txt   # a commit after the PR head
sq squash4; pr_json squash4 10 "$(git -C $WT/squash4 rev-parse HEAD)" release                        # merged into another branch
sq squash5                                                                                           # no merged PR at all
LISTING --json > $P/l4.json 2>&1
check "$(wfield $P/l4.json /.worktrees/squash1 merged)" "true" "squash1: listed merged"
check "$(wfield $P/l4.json /.worktrees/squash1 merged_by)" '"pr"' "…by its pull request"
check "$(wfield $P/l4.json /.worktrees/squash1 pr)" '{"number": 7, "url": "https://example.test/pr/7", "headRefOid": "'$(git -C $WT/squash1 rev-parse HEAD)'", "mergedAt": "2026-10-26T00:00:00Z"}' "…and records which"
check "$(wfield $P/l4.json /.worktrees/squash1 pushed)" "true" "…its commit counts as pushed (it is inside the merged PR)"
check "$(wfield $P/l4.json /.worktrees/squash3 merged)" "false" "squash3: not merged (a commit the PR does not contain)"
check "$(wfield $P/l4.json /.worktrees/squash3 unpushed_commits)" "2" "…both its commits are on no remote"
check "$(wfield $P/l4.json /.worktrees/squash4 merged)" "false" "squash4: not merged (the PR went into another branch)"
check "$(wfield $P/l4.json /.worktrees/squash5 merged)" "false" "squash5: not merged (no merged PR)"
LISTING --prune --idle-for 0s > $P/p4.out 2>&1; check $? 0 "--prune with squash-merged branches"
[ ! -e $WT/squash1 ] && [ ! -e $WT/squash2 ]; check $? 0 "the squash-merged worktrees are removed"
branch_exists squash1 && branch_exists squash2; check $? 0 "…their branches are kept without --delete-branches"
grep -q 'squash-merged; --delete-branches removes it' $P/p4.out; check $? 0 "…and the output says so"
[ -d $WT/squash3 ] && [ -d $WT/squash4 ] && [ -d $WT/squash5 ]; check $? 0 "control: worktrees not covered by a merged PR survive"
grep -q 'does not contain' $P/p4.out; check $? 0 "…squash3 says why"
# --delete-branches: the branch of a squash-merged worktree, for a branch whose merged PR holds everything
sq squash6; pr_json squash6 11 "$(git -C $WT/squash6 rev-parse HEAD)"
LISTING --prune --delete-branches --idle-for 0s > $P/p4b.out 2>&1; check $? 0 "--prune --delete-branches"
[ ! -e $WT/squash6 ] && ! branch_exists squash6; check $? 0 "…removes the worktree and the squash-merged branch"
branch_exists squash3; check $? 0 "control: the branch of a kept worktree stays"
# gh missing the answer: unknown, once, and nothing squash-merged is removed
sq squash7; pr_json squash7 12 "$(git -C $WT/squash7 rev-parse HEAD)"
GH_STUB_FAIL=1 LISTING --prune --idle-for 0s > $P/p4c.out 2>&1; check $? 0 "gh failing (not logged in)"
[ -d $WT/squash7 ]; check $? 0 "…keeps the worktree"
[ "$(grep -c 'merge state unknown for squash-merged branches' $P/p4c.out)" = 1 ]; check $? 0 "…and says that the merge state is unknown, once"
grep -q 'gh is unavailable (gh: not logged in' $P/p4c.out; check $? 0 "…with gh's own reason"
LISTING --prune --no-gh --idle-for 0s > $P/p4d.out 2>&1; [ -d $WT/squash7 ]; check $? 0 "--no-gh: kept as well"
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/squash7 ]; check $? 0 "positive control: with gh answering it goes"

# ---- 5. the caller's own directory
add_wt feat/here; merge_into_main feat/here 2>/dev/null
( cd $WT/feat/here && PATH=$STUB:$PATH $B/agent worktrees --prune --idle-for 0s > $P/p5.out 2>&1 ); check $? 0 "--prune run from inside a removable worktree"
[ -d $WT/feat/here ]; check $? 0 "the caller's own worktree is kept"
grep -q 'your current directory' $P/p5.out; check $? 0 "…and the output says so"
( cd $WT/feat/here/. && PATH=$STUB:$PATH $B/agent worktrees --repo $REPO --prune --idle-for 0s > $P/p5b.out 2>&1 ); [ -d $WT/feat/here ]; check $? 0 "…also with --repo naming the repository"
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/feat/here ]; check $? 0 "positive control: from elsewhere it is removed"

# ---- 6. unknown use (a worktree made by hand): only when idle long enough
git -C $REPO worktree add -q -b by-hand $P/by-hand origin/main
LISTING --json > $P/l6.json 2>&1
check "$(wfield $P/l6.json /by-hand kind)" '"other"' "a worktree made by hand: other"
check "$(wfield $P/l6.json /by-hand live)" '"unknown"' "…use unknown"
LISTING --prune > $P/p6.out 2>&1; [ -d $P/by-hand ]; check $? 0 "unknown use and changed a moment ago: kept"
grep -q 'use unknown, changed' $P/p6.out; check $? 0 "…the output says why"
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $P/by-hand ]; check $? 0 "positive control: past the idle limit it goes"
# a process inside keeps it even when it has been idle for ever
git -C $REPO worktree add -q -b busy $P/busy origin/main
( cd $P/busy && exec sleep 60 ) & SLEEP=$!
sleep 1
LISTING --prune --idle-for 0s > $P/p6b.out 2>&1
if grep -q 'no /proc and no lsof' $P/p6b.out; then echo "SKIP a process inside keeps the worktree (this host cannot list processes)"; kill $SLEEP 2>/dev/null
else
  [ -d $P/busy ]; check $? 0 "a process whose directory is inside: kept even with --idle-for 0s"
  grep -q "in use: sleep (pid $SLEEP)" $P/p6b.out; check $? 0 "…named in the output"
  kill $SLEEP 2>/dev/null; wait $SLEEP 2>/dev/null
  LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $P/busy ]; check $? 0 "positive control: the process gone, the worktree goes"
fi

# ---- 7. hubs: <stage>-hub-<n> in .claude/worktrees; the registered hub is in use, an older one is not
HW=$REPO/.claude/worktrees
mkdir -p $HW
for n in 3 4; do git -C $REPO worktree add -q -b worktree-stx-hub-$n $HW/stx-hub-$n origin/main; done
LISTING --json > $P/l7.json 2>&1
check "$(wfield $P/l7.json /stx-hub-3 who)" '"hub of stx #3"' "a hub worktree: hub of the stage"
check "$(wfield $P/l7.json /stx-hub-3 live)" '"unknown"' "…its use unknown while the stage has no registry"
$B/roles --stage stx set hub 11111111-1111-4111-8111-111111111111 --kind cli --tag hub-4 > /dev/null; check $? 0 "hub-4 registered for the stage"
python3 - $AGENT_HUB_HOME/stx/roles.json $HW/stx-hub-4 <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["roles"]["hub"]["worktree"] = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps(d))
PY
LISTING --json > $P/l7b.json 2>&1
check "$(wfield $P/l7b.json /stx-hub-4 live)" '"yes"' "the registered hub's worktree is in use"
check "$(wfield $P/l7b.json /stx-hub-3 live)" '"no"' "an older hub's worktree is not (a later hub took the stage over)"
LISTING --prune --idle-for 0s > $P/p7.out 2>&1; check $? 0 "--prune with hub worktrees"
[ -d $HW/stx-hub-4 ] && [ ! -e $HW/stx-hub-3 ]; check $? 0 "the superseded hub's worktree goes at once, the registered hub's stays"
grep -q 'registered hub of stage stx' $P/p7.out; check $? 0 "…the output names the registration"

# ---- 8a. a moved worktree looks like a deleted one: its registration (index, HEAD) is kept
add_wt feat/moved; commit_in feat/moved mv.txt; merge_into_main feat/moved; echo staged > $WT/feat/moved/staged.txt; G -C $WT/feat/moved add staged.txt
mv $WT/feat/moved $P/moved-away
LISTING --prune > $P/p8a.out 2>&1; check $? 0 "--prune with a worktree moved away by hand"
git -C $REPO worktree list --porcelain | grep -q 'feat/moved'; check $? 0 "its registration is kept"
grep -q 'feat/moved — directory missing' $P/p8a.out; check $? 0 "…and the output says why"
git -C $REPO worktree repair $P/moved-away > /dev/null 2>&1; [ "$(git -C $P/moved-away status --porcelain)" = "A  staged.txt" ]; check $? 0 "git worktree repair brings it back with its staged file"
git -C $REPO worktree remove --force $P/moved-away; git -C $REPO branch -q -D feat/moved
# ---- 8. locked, missing, a git operation under way
add_wt feat/locked; merge_into_main feat/locked 2>/dev/null; git -C $REPO worktree lock --reason "on a USB stick" $WT/feat/locked
add_wt feat/rebase; merge_into_main feat/rebase 2>/dev/null; mkdir -p "$(git -C $WT/feat/rebase rev-parse --absolute-git-dir)/rebase-merge"
add_wt feat/gone; merge_into_main feat/gone 2>/dev/null; rm -rf $WT/feat/gone
LISTING --prune --idle-for 0s > $P/p8.out 2>&1; check $? 0 "--prune with a locked, a mid-rebase and a deleted worktree"
[ -d $WT/feat/locked ] && grep -q 'locked: on a USB stick' $P/p8.out; check $? 0 "a locked worktree is kept"
[ -d $WT/feat/rebase ] && grep -q 'rebase in progress' $P/p8.out; check $? 0 "a worktree in the middle of a rebase is kept"
git -C $REPO worktree list --porcelain | grep -q 'feat/gone'; check $? 0 "a deleted directory: its registration is kept (git worktree prune is never run)"
grep -q 'missing (1):' $P/p8.out; check $? 0 "…and counted as missing"
branch_exists feat/gone; check $? 0 "…its branch is not touched"
LISTING > $P/l8.out 2>&1; grep -q '^\.worktrees/feat/gone .* missing ' $P/l8.out; check $? 0 "…the listing shows it as missing"

# ---- 8b. changes git status does not show (skip-worktree) keep the worktree
add_wt feat/skip; commit_in feat/skip s.txt; merge_into_main feat/skip
echo edited > $WT/feat/skip/s.txt; git -C $WT/feat/skip update-index --skip-worktree s.txt
[ -z "$(git -C $WT/feat/skip status --porcelain)" ]; check $? 0 "control: git status shows nothing for the skip-worktree edit"
LISTING --prune --idle-for 0s > $P/p8b.out 2>&1; [ -d $WT/feat/skip ] && [ "$(cat $WT/feat/skip/s.txt)" = edited ]; check $? 0 "the worktree with a hidden edit survives --prune"
git -C $WT/feat/skip update-index --no-skip-worktree s.txt; git -C $WT/feat/skip checkout -q -- s.txt
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/feat/skip ]; check $? 0 "positive control: with the edit undone it goes"

# ---- 8c. --prune fetches first: a remote that took the merge back no longer counts the branch as merged
add_wt feat/rolled; commit_in feat/rolled r.txt; merge_into_main feat/rolled
git -C $REMOTE update-ref refs/heads/main "$(git -C $REPO rev-parse feat/rolled~1)"   # as a force-push would
LISTING --json > $P/l8c.json 2>&1; check "$(wfield $P/l8c.json /.worktrees/feat/rolled merged)" "true" "control: without a fetch the stale origin/main still says merged"
LISTING --prune --dry-run --no-fetch --idle-for 0s > $P/p8c1.out 2>&1; grep -q 'feat/rolled — refs not fresh (--no-fetch)' $P/p8c1.out && grep -q 'would remove 0' $P/p8c1.out; check $? 0 "…which --prune --no-fetch does not act on, even in a dry run"
LISTING --prune --idle-for 0s > $P/p8c2.out 2>&1; check $? 0 "--prune (fetches first)"
[ -d $WT/feat/rolled ] && grep -q 'branch not merged into origin/main' $P/p8c2.out; check $? 0 "…the branch is no longer merged and stays"
LISTING --no-fetch > $P/u6.out 2>&1; check $? 2 "--no-fetch without --prune is a usage error"

# ---- 10. the second review: five ways the first version could lose work
# 10a. a missing directory keeps its registration whatever its age: `git worktree prune --expire` compares the index's
#      mtime, not how long the directory has been gone, and a worktree moved by hand or on an unmounted disk looks the same
add_wt feat/vanish; echo v1 > $WT/feat/vanish/v.txt; G -C $WT/feat/vanish add v.txt; echo v2 > $WT/feat/vanish/v.txt
python3 -c 'import os,sys,time; t=time.time()-3*86400; os.utime(sys.argv[1],(t,t))' "$(git -C $WT/feat/vanish rev-parse --absolute-git-dir)/index"
mv $WT/feat/vanish $P/vanish-away
LISTING --prune > $P/p10a.out 2>&1; check $? 0 "--prune with a worktree moved away, its index three days old"
git -C $REPO worktree list --porcelain | grep -q 'feat/vanish'; check $? 0 "its registration is kept (an old index proves nothing about the work)"
grep -q 'feat/vanish — directory missing' $P/p10a.out; check $? 0 "…kept as missing, said so"
git -C $REPO worktree repair $P/vanish-away > /dev/null 2>&1
[ "$(git -C $P/vanish-away diff --cached --name-only)" = v.txt ] && [ "$(cat $P/vanish-away/v.txt)" = v2 ]; check $? 0 "git worktree repair brings back both its staged and its working version"
git -C $REPO worktree remove --force $P/vanish-away; git -C $REPO branch -q -D feat/vanish
# 10b. a worktree that holds another registered worktree is never removed: git removes a directory recursively
add_wt feat/outer; printf '/.worktrees/\n' >> $REPO/.git/info/exclude
git -C $REPO worktree add -q -b feat/inner $WT/feat/outer/.worktrees/inner origin/main
echo wip > $WT/feat/outer/.worktrees/inner/wip.txt
[ -z "$(git -C $WT/feat/outer status --porcelain)" ]; check $? 0 "control: the outer worktree is clean (the nested one is ignored in it)"
LISTING --prune --idle-for 0s > $P/p10b.out 2>&1; check $? 0 "--prune with a dirty worktree nested in a removable one"
[ -f $WT/feat/outer/.worktrees/inner/wip.txt ]; check $? 0 "the nested worktree's uncommitted file survives"
[ -d $WT/feat/outer ] && grep -q 'feat/outer — holds the worktree .worktrees/feat/outer/.worktrees/inner' $P/p10b.out; check $? 0 "…the outer one is kept, saying which worktree it holds"
rm $WT/feat/outer/.worktrees/inner/wip.txt
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/feat/outer/.worktrees/inner ] && [ -d $WT/feat/outer ]; check $? 0 "positive control: clean, the inner one goes (the outer one waits for the next run)"
LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $WT/feat/outer ]; check $? 0 "…and the next run removes the outer one"
# 10c. refs that could not be refreshed decide nothing: a failed fetch or --no-fetch removes nothing
add_wt feat/net main; commit_in feat/net n.txt; merge_into_main feat/net   # from local main: 8c left it ahead of origin/main
git -C $REMOTE update-ref refs/heads/main "$(git -C $REPO rev-parse feat/net~1)"   # the server took the merge back
git -C $REPO remote set-url origin $P/unreachable.git
LISTING --prune --idle-for 0s > $P/p10c.out 2>&1; check $? 0 "--prune with the fetch failing"
[ -d $WT/feat/net ] && grep -q 'feat/net — refs not fresh (git fetch origin failed' $P/p10c.out; check $? 0 "a failed fetch: the stale merge removes nothing (kept: refs not fresh)"
git -C $REPO remote set-url origin $REMOTE
LISTING --prune --no-fetch --idle-for 0s > $P/p10c2.out 2>&1; check $? 0 "--prune --no-fetch"
[ -d $WT/feat/net ] && grep -q 'feat/net — refs not fresh (--no-fetch)' $P/p10c2.out; check $? 0 "…shows the candidate and removes nothing"
LISTING --prune --idle-for 0s > $P/p10c3.out 2>&1; [ -d $WT/feat/net ] && grep -q 'feat/net — branch not merged into origin/main' $P/p10c3.out; check $? 0 "control: fetched, the rollback is seen and the worktree stays for that"
add_wt feat/del; commit_in feat/del del.txt; git -C $REPO push -q origin feat/del 2>/dev/null
git -C $REMOTE branch -q -D feat/del                                                  # deleted on the server
LISTING --json --fetch > $P/l10c.json 2>&1
check "$(wfield $P/l10c.json /.worktrees/feat/del unpushed_commits)" "1" "the fetch prunes the refs of server-deleted branches: the commit is on no remote again"
# 10d. --delete-branches deletes the ref only at the commit it verified, and only when no worktree has it checked out
sq sqrace; A=$(git -C $WT/sqrace rev-parse HEAD); pr_json sqrace 13 $A
cat > $GHDIR/sqrace.hook <<EOF
git -C $WT/sqrace checkout -q --detach
git -C $REPO update-ref refs/heads/sqrace \$(git -C $REPO -c user.email=t@t -c user.name=t commit-tree $A^{tree} -p $A -m unpublished)
git -C $REPO rev-parse refs/heads/sqrace > $P/sqrace.B
EOF
LISTING --prune --delete-branches --idle-for 0s > $P/p10d.out 2>&1; check $? 0 "--prune --delete-branches while the branch moves to an unpublished commit"
[ "$(git -C $REPO rev-parse -q --verify refs/heads/sqrace)" = "$(cat $P/sqrace.B)" ]; check $? 0 "the branch and its unpublished commit survive"
grep -q 'branch sqrace kept (it moved' $P/p10d.out; check $? 0 "…said so"
[ ! -e $WT/sqrace ]; check $? 0 "…while the worktree, detached at the merged commit, goes"
sq sqbusy; A=$(git -C $WT/sqbusy rev-parse HEAD); pr_json sqbusy 14 $A
printf 'git -C %s checkout -q --detach\ngit -C %s worktree add -q %s sqbusy\n' $WT/sqbusy $REPO $P/sqbusy-2 > $GHDIR/sqbusy.hook
LISTING --prune --delete-branches --idle-for 0s > $P/p10d2.out 2>&1
branch_exists sqbusy && [ "$(git -C $P/sqbusy-2 symbolic-ref -q HEAD)" = refs/heads/sqbusy ]; check $? 0 "a branch checked out in another worktree meanwhile is not deleted"
grep -q 'branch sqbusy kept (checked out in' $P/p10d2.out; check $? 0 "…said so"
# 10e. paths compare by identity, not by spelling: a case-insensitive file system (macOS) spells one directory many ways
mkdir -p $P/CaseDir
if [ ! -d $P/casedir ]; then echo "SKIP paths of another case (a case-sensitive file system)"
else
  git -C $REPO worktree add -q -b feat/case $P/casedir/wt origin/main; mkdir -p $P/CaseDir/wt/deep/er
  [ "$(git -C $REPO worktree list --porcelain | grep -c '/casedir/wt$')" = 1 ]; check $? 0 "control: git registered the lower-case spelling"
  ( cd $P/CaseDir/wt/deep/er && exec sleep 60 ) & SLEEP=$!
  sleep 1
  LISTING --prune --idle-for 0s > $P/p10e.out 2>&1
  [ -d $P/CaseDir/wt ] && grep -q "in use: sleep (pid $SLEEP)" $P/p10e.out; check $? 0 "a process deep inside, by the on-disk spelling: kept"
  kill $SLEEP 2>/dev/null; wait $SLEEP 2>/dev/null
  ( cd $P/CaseDir/wt/deep/er && PATH=$STUB:$PATH $B/agent worktrees --repo $REPO --prune --idle-for 0s > $P/p10e2.out 2>&1 )
  [ -d $P/CaseDir/wt ] && grep -q 'your current directory' $P/p10e2.out; check $? 0 "the caller deep inside, by the on-disk spelling: kept"
  LISTING --prune --idle-for 0s > /dev/null 2>&1; [ ! -e $P/CaseDir/wt ]; check $? 0 "positive control: from elsewhere, with nobody inside, it goes"
fi

# ---- 9. usage, output
LISTING --dry-run > $P/u1.out 2>&1; check $? 2 "--dry-run without --prune is a usage error"
LISTING --delete-branches > $P/u2.out 2>&1; check $? 2 "--delete-branches without --prune is a usage error"
LISTING --idle-for soon > $P/u3.out 2>&1; check $? 2 "a bad --idle-for is a usage error"
( cd $P && $B/agent worktrees --repo $P/not-a-repo > $P/u4.out 2>&1 ); check $? 2 "a directory that is no repository is a usage error"
mkdir -p $P/plain; ( cd $P/plain && $B/agent worktrees > $P/u5.out 2>&1 ); check $? 2 "…also as the working directory"
LISTING > $P/table.out 2>&1; check $? 0 "the plain listing"
head -2 $P/table.out | tail -1 | grep -q '^PATH .*BRANCH .*WHO .*LIVE .*DIRTY .*ON REMOTE .*MERGED .*AGE .*PRUNE'; check $? 0 "…has a header with every column of the ledger"
grep -q ' worktrees, .* removable by `agent worktrees --prune`' $P/table.out; check $? 0 "…and a summary"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repo"] and d["worktrees"][0]["main"] and d["worktrees"][0]["removable"] is False' $P/l7b.json; check $? 0 "--json: the main checkout is listed and never removable"
exit $fail
