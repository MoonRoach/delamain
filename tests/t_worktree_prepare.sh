#!/bin/bash
# agent spawn --worktree prepares the worktree before the agent starts: `.agents/linked` paths become symlinks to the
# primary checkout's copies, `.agents/prepare` runs once (success, non-zero exit, timeout, not executable, absent), and
# every worktree has a slot — unique among the repository's live worktrees, stable across re-spawns, exported to the
# agent as AGENT_HUB_SLOT (Claude and Codex), shown by status. Stand-in CLIs.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
R=$AGENT_HUB_HOME; P=$(mktemp -d); echo "brief: do the thing" > $P/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
meta(){ python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" $R/stage-a/agents/$1/meta.json "$2"; }
spawn(){ local role=$1 repo=$2; shift 2; $B/agent spawn --role $role --cwd $repo --model haiku --brief $P/b.md --worktree "$@"; }
mkrepo(){ git init -q -b main $1 && printf '.env\nconfig/local.json\nmissing.txt\n' > $1/.gitignore
  git -C $1 add .gitignore && git -C $1 -c user.email=t@t -c user.name=t commit -q -m init; }
commit_all(){ git -C $1 add -A && git -C $1 -c user.email=t@t -c user.name=t commit -q -m "$2"; }

# ---- 1. a repository with both files
P=$(cd $P && pwd -P); REPO=$P/app; mkrepo $REPO; mkdir -p $REPO/.agents $REPO/config
printf '# shared secrets\n.env\n\nconfig/local.json\nmissing.txt\nlocal.cfg\n/etc/passwd\n../outside\n.git/config\n' > $REPO/.agents/linked
cat > $REPO/.agents/prepare <<'SH'
#!/bin/sh
echo "slot=$AGENT_HUB_SLOT role=$AGENT_ROLE stage=$HUB_STAGE tag=$HUB_TAG engine=$AGENT_HUB_ENGINE cwd=$(pwd -P)" > prepared.txt
echo "prepare output line"
echo run >> "$AGENT_HUB_MAIN_CHECKOUT/prepare-runs.txt"
SH
chmod +x $REPO/.agents/prepare; commit_all $REPO "agents files"
echo "SECRET=1" > $REPO/.env; echo x > $REPO/local.cfg; echo '{"k":1}' > $REPO/config/local.json
spawn one $REPO > $P/s1.out 2> $P/s1.err; check $? 0 "spawn --worktree in a repository with .agents/linked and .agents/prepare"
wait_dead one
WT=$REPO/.worktrees/agent/one
[ -L $WT/.env ] && [ "$(readlink $WT/.env)" = "$REPO/.env" ] && [ "$(cat $WT/.env)" = "SECRET=1" ]; check $? 0 "a linked .env is a symlink to the main checkout's file"
[ -L $WT/config/local.json ] && [ "$(readlink $WT/config/local.json)" = "$REPO/config/local.json" ]; check $? 0 "a nested linked path gets its directory and a symlink"
[ ! -e $WT/missing.txt ] && grep -q 'note: missing.txt is not in the primary checkout' $P/s1.err; check $? 0 "a path missing in the main checkout is a note, not a failure"
grep -q "note: .agents/linked: '/etc/passwd' is not linked" $P/s1.err && grep -q "'../outside' is not linked" $P/s1.err; check $? 0 "an absolute path and .. are rejected with a message"
grep -q "'.git/config' is not linked" $P/s1.err && [ ! -L $WT/.git/config ]; check $? 0 "a path into .git is rejected too"
grep -q "linked .env -> $REPO/.env" $P/s1.out; check $? 0 "the spawn output names the link"
grep -q 'note: local.cfg is not git-ignored' $P/s1.err && [ ! -e $WT/local.cfg ]; check $? 0 "a path git does not ignore is not linked, with a note"
! git -C $WT status --porcelain | grep -q 'local.cfg\|\.env'; check $? 0 "…so git sees no link in the worktree (git worktree remove would not refuse)"
grep -q 'slot=1 role=one stage=stage-a tag=one engine=claude cwd='"$(cd $WT && pwd -P)" $WT/prepared.txt; check $? 0 "prepare ran in the worktree with the slot, role, stage, tag and engine"
grep -q 'prepare output line' $R/stage-a/agents/one/prepare.log && ! grep -q 'prepare output line' $P/s1.out; check $? 0 "its output is in the run directory's prepare.log, not in the spawn output"
check "$(grep -c . $REPO/prepare-runs.txt)" 1 "prepare ran once"
grep -qx 'AGENT_HUB_SLOT=1' $WT/env.log; check $? 0 "the agent's environment carries AGENT_HUB_SLOT=1"
grep -q "worktree's slot is 1 (\$AGENT_HUB_SLOT)" $WT/prompts.log; check $? 0 "the spawn footer tells the agent its slot"
check "$(meta one 'm["worktree"]["slot"]')" 1 "meta records the slot"
$B/agent status one | grep -q "; worktree .*agent/one (agent/one), slot 1"; check $? 0 "status shows the slot"
grep -q 'worktree .*agent/one (agent/one), slot 1' $(journal stage-a); check $? 0 "the start line shows the slot"

# ---- 2. a second worktree gets another slot; a re-spawn keeps the first one and does not prepare again
spawn two $REPO > $P/s2.out 2>&1; check $? 0 "a second worktree"
wait_dead two
check "$(meta two 'm["worktree"]["slot"]')" 2 "…gets slot 2"
rm $WT/.env
spawn one $REPO > $P/s3.out 2>&1; check $? 0 "re-spawn into the first worktree"
wait_dead one
grep -q reused $P/s3.out && [ "$(meta one 'm["worktree"]["slot"]')" = 1 ] && grep -qx 'AGENT_HUB_SLOT=1' $WT/env.log; check $? 0 "…reused, the same slot 1 in meta and in the agent's environment"
[ -L $WT/.env ]; check $? 0 "…and the missing link is restored (linking is idempotent on a reused worktree)"
check "$(grep -c . $REPO/prepare-runs.txt)" 2 "…prepare did not run again (two worktrees, two runs)"
spawn one $REPO > $P/s3b.out 2> $P/s3b.err; wait_dead one
! grep -q '^linked ' $P/s3b.out; check $? 0 "a second re-spawn does not report links that already exist"

# ---- 3. a worktree made by hand: a real file is not overwritten, no prepare, still a slot
git -C $REPO worktree add -q -b hand $P/hand-wt
echo "MINE" > $P/hand-wt/.env
spawn h $REPO hand > $P/s4.out 2> $P/s4.err; check $? 0 "a hand-made worktree"
wait_dead h
[ ! -L $P/hand-wt/.env ] && [ "$(cat $P/hand-wt/.env)" = MINE ] && grep -q 'note: .env exists in the worktree as a real file' $P/s4.err; check $? 0 "a real file at a linked path stays and is reported"
[ -L $P/hand-wt/config/local.json ]; check $? 0 "…the other paths are linked"
[ ! -e $P/hand-wt/prepared.txt ] && check "$(grep -c . $REPO/prepare-runs.txt)" 2 "a reused hand-made worktree is not prepared"
check "$(meta h 'm["worktree"]["slot"]')" 3 "…but has a slot"

# ---- 4. a freed slot is reused
git -C $REPO worktree remove --force $REPO/.worktrees/agent/two
spawn four $REPO > /dev/null 2>&1; wait_dead four
check "$(meta four 'm["worktree"]["slot"]')" 2 "the slot of a removed worktree is free again"

# ---- 4b. the same role again at a path with an old record: a new worktree, prepared again
spawn rr $REPO > /dev/null 2>&1; wait_dead rr
RUNS=$(grep -c . $REPO/prepare-runs.txt); SLOT1=$(meta rr 'm["worktree"]["slot"]')
git -C $REPO worktree remove --force $REPO/.worktrees/agent/rr && git -C $REPO branch -q -D agent/rr
spawn rr $REPO > $P/rr.out 2>&1; check $? 0 "the role spawned again after its worktree was removed"
wait_dead rr
grep -q 'created' $P/rr.out && [ "$(grep -c . $REPO/prepare-runs.txt)" = $((RUNS + 1)) ] && [ -f $REPO/.worktrees/agent/rr/prepared.txt ]; check $? 0 "…the new worktree is prepared again"
check "$(meta rr 'm["worktree"]["slot"]')" "$SLOT1" "…and keeps the slot of that path"
spawn rr $REPO > /dev/null 2>&1; wait_dead rr
check "$(grep -c . $REPO/prepare-runs.txt)" $((RUNS + 1)) "…then, reused, it is not prepared a third time"

# ---- 4b2. a recreated path: a failing prepare, or --no-prepare, is not forgotten (the record on disk says unprepared)
XR=$P/recreate; mkrepo $XR; mkdir $XR/.agents
printf '#!/bin/sh\necho run >> "$AGENT_HUB_MAIN_CHECKOUT/runs.txt"\n' > $XR/.agents/prepare; chmod +x $XR/.agents/prepare; commit_all $XR ok
spawn x $XR > /dev/null 2>&1; wait_dead x
git -C $XR worktree remove --force $XR/.worktrees/agent/x && git -C $XR branch -q -D agent/x
printf '#!/bin/sh\necho run >> "$AGENT_HUB_MAIN_CHECKOUT/runs.txt"\nexit 3\n' > $XR/.agents/prepare; commit_all $XR failing
spawn x $XR > $P/x1.out 2>&1; check $? 1 "a recreated path whose prepare fails: the spawn fails"
spawn x $XR > $P/x2.out 2>&1; check $? 1 "…and the next spawn into that worktree runs the prepare again, and fails again"
check "$(grep -c . $XR/runs.txt)" 3 "…(runs: the first worktree, then two failures)"
YR=$P/recreate2; mkrepo $YR; mkdir $YR/.agents
printf '#!/bin/sh\necho run >> "$AGENT_HUB_MAIN_CHECKOUT/runs.txt"\n' > $YR/.agents/prepare; chmod +x $YR/.agents/prepare; commit_all $YR ok
spawn y $YR > /dev/null 2>&1; wait_dead y
git -C $YR worktree remove --force $YR/.worktrees/agent/y && git -C $YR branch -q -D agent/y
spawn y $YR --no-prepare > /dev/null 2>&1; check $? 0 "a recreated path with --no-prepare starts the agent"
wait_dead y
check "$(grep -c . $YR/runs.txt)" 1 "…without running the prepare"
spawn y $YR > /dev/null 2>&1; wait_dead y
check "$(grep -c . $YR/runs.txt)" 2 "…the next spawn into that worktree runs it"

# ---- 4c. a link leaves the worktree through a symlinked directory: refused
ER=$P/esc; mkrepo $ER; mkdir -p $P/victim/sub $ER/.agents; echo v > $P/victim/sub/x.env
VICTIM_BEFORE=$(cd $P && find victim | sort | tr '\n' ' ')
ln -s ../victim $ER/cfg; echo 'cfg/sub/x.env' > $ER/.agents/linked
commit_all $ER esc
spawn e $ER > $P/e1.out 2> $P/e1.err; check $? 0 "a worktree whose linked path runs through a symlinked directory"
grep -q 'cfg/sub/x.env: its directory leads out of the worktree' $P/e1.err && [ ! -e $ER/.worktrees/agent/victim ] && [ "$(cd $P && find victim | sort | tr '\n' ' ')" = "$VICTIM_BEFORE" ]; check $? 0 "…is refused with a note, and neither the worktree's neighbours nor the link target's directory changed"

# ---- 4d. a repository whose git dir is elsewhere (--separate-git-dir): no primary checkout to share from, said plainly
SR=$P/sep; git init -q -b main --separate-git-dir=$P/sep.git $SR; mkdir $SR/.agents; printf '.env\n' > $SR/.gitignore; echo .env > $SR/.agents/linked
commit_all $SR sep; echo S=1 > $SR/.env
spawn s $SR > $P/sep.out 2>&1; check $? 0 "a repository with a separate git dir"
grep -q 'no primary checkout to share from' $P/sep.out && [ ! -e $SR/.worktrees/agent/s/.env ]; check $? 0 "…nothing is linked and a note says why"

# ---- 5. control: without --worktree there is no slot
$B/agent spawn --role plain --cwd $P --model haiku --brief $P/b.md > /dev/null 2>&1; wait_dead plain
grep -qx 'AGENT_HUB_SLOT=<unset>' $P/env.log; check $? 0 "control: an agent without --worktree gets no AGENT_HUB_SLOT"
AGENT_HUB_SLOT=9 $B/agent spawn --role plain2 --cwd $P --model haiku --brief $P/b.md > /dev/null 2>&1; wait_dead plain2
tail -n 20 $P/env.log | grep -qx 'AGENT_HUB_SLOT=9'; check $? 1 "…and the caller's own AGENT_HUB_SLOT is not passed on"

# ---- 6. concurrent spawns never share a slot
CR=$P/conc; mkrepo $CR
for n in 1 2 3 4 5; do spawn c$n $CR > $P/c$n.out 2>&1 & done; wait
for n in 1 2 3 4 5; do wait_dead c$n; done
SLOTS=$(for n in 1 2 3 4 5; do meta c$n 'm["worktree"]["slot"]'; done | sort -n | tr '\n' ' ')
check "$SLOTS" "1 2 3 4 5 " "five concurrent spawns got five distinct slots"

# ---- 7. prepare fails: the spawn fails with the exit code and the log tail
FR=$P/fail; mkrepo $FR; mkdir $FR/.agents
printf '#!/bin/sh\necho "about to fail"\necho boom >&2\nexit 3\n' > $FR/.agents/prepare; chmod +x $FR/.agents/prepare; commit_all $FR prep
spawn bad $FR > $P/f1.out 2>&1; check $? 1 "negative: a prepare that exits non-zero fails the spawn (exit 1)"
grep -q 'exited with code 3' $P/f1.out && grep -q 'boom' $P/f1.out && grep -q 'about to fail' $P/f1.out; check $? 0 "…the output has the exit code and the last lines of the log"
grep -q 'worktree prepare of .* failed: .agents/prepare exited with code 3' $(journal stage-a); check $? 0 "…and the journal has one line"
ls -d $R/stage-a/agents/bad.failed-* > /dev/null 2>&1 && [ ! -e $R/stage-a/agents/bad ] && ls $R/stage-a/agents/bad.failed-*/prepare.log > /dev/null; check $? 0 "…the run directory is kept as bad.failed-… with prepare.log"
$B/roles --stage stage-a list 2>&1 | grep -q ' bad ' ; check $? 1 "…and no agent is registered"
spawn bad $FR --no-prepare > $P/f2.out 2> $P/f2.err; check $? 0 "--no-prepare starts the agent anyway"
grep -q 'note: --no-prepare' $P/f2.err; check $? 0 "…with a note"
wait_dead bad
spawn bad $FR > $P/f3.out 2>&1; check $? 1 "the next spawn into that worktree runs the prepare again (still failing)"
printf '#!/bin/sh\necho fixed > fixed.txt\n' > $FR/.worktrees/agent/bad/.agents/prepare
spawn bad $FR > $P/f4.out 2>&1; check $? 0 "once the script is fixed in the worktree the spawn works"
wait_dead bad
[ -f $FR/.worktrees/agent/bad/fixed.txt ]; check $? 0 "…and the prepare ran"
rm $FR/.worktrees/agent/bad/fixed.txt
spawn bad $FR > /dev/null 2>&1; wait_dead bad
[ ! -e $FR/.worktrees/agent/bad/fixed.txt ]; check $? 0 "…and only once: a successful prepare is not repeated"

# two failures of one role within a second leave two directories, and the next spawn is not in their way
spawn bad2 $FR > /dev/null 2>&1; spawn bad2 $FR > /dev/null 2>&1; spawn bad2 $FR > /dev/null 2>&1
[ "$(ls -d $R/stage-a/agents/bad2.failed-* | wc -l | tr -d ' ')" = 3 ] && [ ! -e $R/stage-a/agents/bad2 ]; check $? 0 "three failures of one role in quick succession keep three run directories"

# ---- 8. prepare times out
TR=$P/slow; mkrepo $TR; mkdir $TR/.agents
printf '#!/bin/sh\nsleep 40 &\nwait\n' > $TR/.agents/prepare; chmod +x $TR/.agents/prepare; commit_all $TR prep
START=$SECONDS
AGENT_HUB_PREPARE_TIMEOUT=1 spawn slow $TR > $P/t1.out 2>&1; check $? 1 "negative: a prepare that runs past AGENT_HUB_PREPARE_TIMEOUT fails the spawn"
[ $((SECONDS - START)) -lt 25 ] && grep -q 'did not finish in 1 s' $P/t1.out; check $? 0 "…it is killed and the message says so"
AGENT_HUB_PREPARE_TIMEOUT=abc spawn slow2 $TR > $P/t2.out 2>&1; check $? 2 "negative: a bad AGENT_HUB_PREPARE_TIMEOUT is a usage error"
[ ! -e $TR/.worktrees/agent/slow2 ]; check $? 0 "…before any worktree is made"

# ---- 9. prepare is not executable
NR=$P/noexec; mkrepo $NR; mkdir $NR/.agents
printf '#!/bin/sh\ntouch ran.txt\n' > $NR/.agents/prepare; chmod 644 $NR/.agents/prepare; commit_all $NR prep
spawn ne $NR > $P/n1.out 2> $P/n1.err; check $? 0 "a non-executable .agents/prepare does not fail the spawn"
wait_dead ne
grep -q 'is not executable (chmod +x): not run' $P/n1.err && [ ! -e $NR/.worktrees/agent/ne/ran.txt ]; check $? 0 "…it is reported, not run"

# ---- 10. a repository without the files behaves as before
AR=$P/plainrepo; mkrepo $AR
spawn pl $AR > $P/p1.out 2> $P/p1.err; check $? 0 "a repository without .agents/ files"
wait_dead pl
! grep -qv 'owner-approved plan\|has no origin' $P/p1.err && ! grep -q 'prepared\|linked' $P/p1.out; check $? 0 "…nothing is printed about them"
[ ! -e $R/stage-a/agents/pl/prepare.log ]; check $? 0 "…and no prepare.log exists"

# ---- 11. flags
$B/agent spawn --role nf --cwd $P --model haiku --brief $P/b.md --no-prepare > /dev/null 2>&1; check $? 2 "negative: --no-prepare without --worktree is a usage error"

# ---- 12. Codex
CX=$P/cx; mkrepo $CX; mkdir $CX/.agents; echo ".env" > $CX/.agents/linked
printf '#!/bin/sh\necho "slot=$AGENT_HUB_SLOT engine=$AGENT_HUB_ENGINE" > prepared.txt\n' > $CX/.agents/prepare; chmod +x $CX/.agents/prepare; commit_all $CX prep
echo K=1 > $CX/.env
$B/agent spawn --engine codex --role cdx --cwd $CX --model gpt-fixture --brief $P/b.md --worktree > $P/x1.out 2>&1; check $? 0 "spawn --engine codex --worktree"
wait_dead cdx
CW=$CX/.worktrees/agent/cdx
grep -q 'slot=1 engine=codex' $CW/prepared.txt && [ -L $CW/.env ]; check $? 0 "…prepared and linked before Codex starts"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert r[-1]["AGENT_HUB_SLOT"]=="1", r' $CW/codex-env.jsonl; check $? 0 "…and the Codex run's environment carries AGENT_HUB_SLOT=1"
grep -q "worktree's slot is 1" $CW/codex-prompts.log; check $? 0 "…and its prompt names the slot"
exit $fail
