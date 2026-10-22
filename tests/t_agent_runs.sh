#!/bin/bash
# Runs of a headless agent: `agent send` signs its journal line with the caller's tag (HUB_TAG, the registry entry of
# the calling session, else `cli`), never a hard-coded `hub`; status and agent-top show the last run's turns next to
# the total; `agent spawn --worktree` in a repository with no commits fails with a clear message. Stand-in CLI.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a CLAUDE_BIN=$T/fake_claude.py
R=$AGENT_HUB_HOME; P=$(mktemp -d); W=$P/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
last_line(){ grep -F "$1" $(journal stage-a) | tail -1; }

# ---- 3. the tag of an `agent send` line
H1=11111111-1111-4111-8111-111111111111
FAKE_HOLD=6 $B/agent spawn --role probe --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1; check $? 0 "spawn from a shell without a role"
$B/agent send probe "alive one" > /dev/null; check $? 0 "send to a running agent"
last_line '@probe alive one' | grep -q '^- [0-9:]* \[cli\] @probe alive one'; check $? 0 "…is signed [cli], not [hub]"
wait_dead probe
$B/agent send probe "resume one" > /dev/null; check $? 0 "send to a finished agent (resume)"
last_line '@probe (session resumed' | grep -q '^- [0-9:]* \[cli\] @probe (session resumed'; check $? 0 "…is signed [cli] too"
wait_dead probe
HUB_TAG=ahub-pr9 $B/agent send probe "tagged one" > /dev/null
last_line '@probe (session resumed' | grep -q '\[ahub-pr9\] @probe (session resumed.*tagged one'; check $? 0 "HUB_TAG names the caller"
wait_dead probe
$B/roles --stage stage-a set hub $H1 --tag hub-4 > /dev/null; check $? 0 "a hub registered in the roles registry"
CLAUDE_CODE_SESSION_ID=$H1 $B/agent send probe "from the hub" > /dev/null
last_line '@probe (session resumed' | grep -q '\[hub-4\] @probe (session resumed.*from the hub'; check $? 0 "the hub keeps its hub-<N> tag (registry lookup of its session)"
wait_dead probe
FAKE_HOLD=6 $B/agent spawn --role live2 --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1
CLAUDE_CODE_SESSION_ID=$H1 $B/agent send live2 "hub to alive" > /dev/null
last_line '@live2 hub to alive' | grep -q '\[hub-4\] @live2 hub to alive'; check $? 0 "…also for a message to a running agent"
$B/agent stop live2 > /dev/null; $B/agent stop probe > /dev/null

# ---- 4. turns: the last run's next to the total
FAKE_TURNS=4 $B/agent spawn --role turns --cwd $W --model sonnet --brief $W/b.md > /dev/null 2>&1; check $? 0 "spawn an agent that works 5 turns"
wait_dead turns
$B/agent status turns | grep -q '; turns 5; last:'; check $? 0 "one run: status shows plain turns 5"
FAKE_TURNS=2 $B/agent send turns "go on" > /dev/null; check $? 0 "resume it for 3 more turns"
wait_dead turns
$B/agent status turns | grep -q '; turns 3 (total 8); last:'; check $? 0 "status: turns 3 (total 8)"
grep -q 'ENDED turns: .*turns 3 (total 8)' $(journal stage-a); check $? 0 "the ENDED line says the same"
$B/agent-top --json --stage stage-a > $P/top.json 2>&1
python3 -c 'import json,sys; a={x["role"]:x for x in json.load(open(sys.argv[1]))["agents"]}["turns"]; assert (a["run_turns"], a["turns"])==(3, 8), a' $P/top.json; check $? 0 "agent-top --json: run_turns 3, turns 8"
$B/agent-top --once --stage stage-a --width 120 > $P/top.out 2>&1
grep -E '^[^ ]+ turns ' $P/top.out | grep -q ' 3/8 '; check $? 0 "agent-top --once: the TURN column reads 3/8"
$B/agent-top --once --stage stage-a --agent turns --width 120 > $P/card.out 2>&1
grep -q 'turns 3 (total 8)' $P/card.out; check $? 0 "agent-top card: turns 3 (total 8)"
$B/agent-top --widget --stage stage-a > $P/widget.html 2>&1
grep -q '3 turns (total 8)' $P/widget.html; check $? 0 "agent-top widget: 3 turns (total 8)"
FAKE_TURNS=0 $B/agent spawn --role single --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1; wait_dead single
$B/agent-top --once --stage stage-a --width 120 > $P/top2.out 2>&1
grep -E '^[^ ]+ single ' $P/top2.out | grep -Eq ' 1 '; check $? 0 "negative: an agent of one run keeps a plain TURN cell"
grep -E '^[^ ]+ single ' $P/top2.out | grep -Eq ' [0-9]+/[0-9]+ '; check $? 1 "…without a run/total pair (the MODEL cell of a haiku agent carries its effort, `model/hi`, so a bare slash is no signal)"

# ---- 5. --worktree in a repository with no commits
# (a glyph in the first column of agent-top is matched with [^ ]+, not ".": the tests do not depend on the locale)
git init -q -b main $P/empty
$B/agent spawn --role first --cwd $P/empty --model haiku --brief $W/b.md --worktree > $P/e1.out 2>&1; check $? 1 "spawn --worktree in a repository with no commits fails"
grep -q 'the repository .* has no commits yet — make a first commit' $P/e1.out; check $? 0 "…saying the repository has no commits yet"
[ ! -e $P/empty/.worktrees ] && [ ! -e $R/stage-a/agents/first ] && ! grep -q worktrees $P/empty/.git/info/exclude 2>/dev/null; check $? 0 "…and leaves no worktree, agent directory or exclude line behind"
$B/agent spawn --role nowt --cwd $P/empty --model haiku --brief $W/b.md > /dev/null 2>&1; check $? 0 "positive control: without --worktree an empty repository is fine"
wait_dead nowt
git -C $P/empty -c user.email=t@t -c user.name=t commit -q --allow-empty -m "first commit"
$B/agent spawn --role first --cwd $P/empty --model haiku --brief $W/b.md --worktree > $P/e2.out 2>&1; check $? 0 "positive control: after the first commit the same spawn works"
[ -d $P/empty/.worktrees/agent/first ]; check $? 0 "…in .worktrees/agent/first"
wait_dead first
# the check is for a branch made from HEAD only: an unborn HEAD beside commits on another branch still takes an existing branch
git init -q -b main $P/orph; git -C $P/orph -c user.email=t@t -c user.name=t commit -q --allow-empty -m "first commit"
git -C $P/orph checkout -q --orphan unborn
$B/agent spawn --role ex --cwd $P/orph --model haiku --brief $W/b.md --worktree main > $P/o1.out 2>&1; check $? 0 "HEAD unborn, commits on main: --worktree main (an existing branch) works"
[ -d $P/orph/.worktrees/main ] && [ "$(git -C $P/orph/.worktrees/main rev-parse --abbrev-ref HEAD)" = main ]; check $? 0 "…a worktree of main"
wait_dead ex
$B/agent spawn --role nb --cwd $P/orph --model haiku --brief $W/b.md --worktree brand-new > $P/o2.out 2>&1; check $? 0 "a new branch with HEAD unborn starts from the default branch (main), not from HEAD"
[ "$(git -C $P/orph/.worktrees/brand-new rev-parse HEAD)" = "$(git -C $P/orph rev-parse main)" ]; check $? 0 "…a worktree at main's commit"
wait_dead nb
$B/agent spawn --role nb2 --cwd $P/orph --model haiku --brief $W/b.md --worktree brand-new2 --base HEAD > $P/o3.out 2>&1; check $? 1 "negative: --base HEAD from the unborn HEAD still says there are no commits"
grep -q 'has no commits yet' $P/o3.out; check $? 0 "…naming the reason"

# ---- 6. --worktree and an existing worktree of the branch: a foreign dirty one is not taken over
G="git -c user.email=t@t -c user.name=t"
git init -q -b main $P/fw; $G -C $P/fw commit -q --allow-empty -m "first commit"
echo base > $P/fw/f.txt; git -C $P/fw add f.txt; $G -C $P/fw commit -q -m "f"
git -C $P/fw branch feat; git -C $P/fw branch feat2; git -C $P/fw branch feat3
git -C $P/fw worktree add -q $P/foreign-feat feat
echo "owner draft" > $P/foreign-feat/f.txt
$B/agent spawn --role fw1 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat > $P/f1.out 2>&1; check $? 2 "a foreign worktree of the branch with an uncommitted change: spawn --worktree is refused"
grep -q "$P/foreign-feat.*uncommitted changes and is not an agent worktree.*commit there, or pick another branch" $P/f1.out; check $? 0 "…naming the path, the reason and the way out"
[ "$(cat $P/foreign-feat/f.txt)" = "owner draft" ] && [ ! -e $R/stage-a/agents/fw1 ] && [ ! -e $P/fw/.worktrees ]; check $? 0 "…the file is untouched, no agent and no worktree was created"
grep -Fq -- '--worktree <new-branch> --base feat)' $P/f1.out; check $? 0 "…the remedy uses the local branch, including when it was never pushed"
git -C $P/foreign-feat add f.txt
$B/agent spawn --role fw1 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat > $P/f-staged.out 2>&1; check $? 2 "a foreign worktree with a staged change is refused too"
[ "$(git -C $P/foreign-feat show :f.txt)" = "owner draft" ] && [ "$(cat $P/foreign-feat/f.txt)" = "owner draft" ] && [ ! -e $R/stage-a/agents/fw1 ]; check $? 0 "…the staged draft and working file are untouched, no agent started"
$G -C $P/foreign-feat commit -q -m "draft"
# A broken index makes status fail even though the committed files are clean.
foreign_index=$(git -C $P/foreign-feat rev-parse --path-format=absolute --git-path index)
cp "$foreign_index" "$P/foreign-index.saved"
printf 'invalid index' > "$foreign_index"
$B/agent spawn --role fw1 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat > $P/f-status.out 2>&1; check $? 2 "a failed git status in a foreign worktree is refused"
grep -q 'cannot be inspected.*not an agent worktree' $P/f-status.out && [ ! -e $R/stage-a/agents/fw1 ]; check $? 0 "…with the inspection failure named and no agent started"
cp "$P/foreign-index.saved" "$foreign_index"
$B/agent spawn --role fw1 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat > $P/f2.out 2>&1; check $? 0 "positive control: after the change is committed the same worktree is reused"
foreign_path=$(cd "$P/foreign-feat" && pwd -P)
grep -Fq "worktree $foreign_path on feat (reused)" $P/f2.out && grep -q 'foreign worktree' $P/f2.out; check $? 0 "…as the foreign worktree, with a note"
wait_dead fw1
git -C $P/fw worktree add -q $P/foreign-feat2 feat2; echo new > $P/foreign-feat2/untracked.txt
$B/agent spawn --role fw2 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat2 > $P/f3.out 2>&1; check $? 2 "a foreign worktree with only an untracked file is refused"
[ -e $P/foreign-feat2/untracked.txt ] && [ ! -e $R/stage-a/agents/fw2 ]; check $? 0 "…and nothing was started"
$B/agent spawn --role fw3 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat3 > $P/f4.out 2>&1; check $? 0 "an agent worktree of the branch is created under .worktrees/"
wait_dead fw3
echo "unfinished" > $P/fw/.worktrees/feat3/f.txt
$B/agent spawn --role fw3 --cwd $P/fw --model haiku --brief $W/b.md --worktree feat3 > $P/f5.out 2>&1; check $? 0 "re-spawn into the agent's own .worktrees/ worktree with an uncommitted change is reused"
grep -q "(reused)" $P/f5.out && [ "$(cat $P/fw/.worktrees/feat3/f.txt)" = unfinished ]; check $? 0 "…as it is, the change kept"
wait_dead fw3
# Local-only submodule fixture: ignore settings must not hide another session's drafts.
git init -q -b main $P/sub-source
echo base > $P/sub-source/draft.txt; git -C $P/sub-source add draft.txt
$G -C $P/sub-source commit -q -m "submodule base"
git -c protocol.file.allow=always -C $P/foreign-feat submodule add -q $P/sub-source vendor; check $? 0 "a local submodule fixture is added to the foreign worktree"
$G -C $P/foreign-feat commit -q -am "add submodule"
git -C $P/foreign-feat config submodule.vendor.ignore all
git -C $P/foreign-feat config diff.ignoreSubmodules all
echo "submodule owner draft" > $P/foreign-feat/vendor/draft.txt
git -C $P/foreign-feat status --porcelain --untracked-files=all > $P/sub-hidden.out; check $? 0 "ordinary status succeeds with submodule ignore settings"
[ ! -s $P/sub-hidden.out ] || cat $P/sub-hidden.out
[ ! -s $P/sub-hidden.out ]; check $? 0 "positive control: ordinary status hides the submodule draft"
git -C $P/foreign-feat status --porcelain --untracked-files=all --ignore-submodules=none > $P/sub-visible.out; check $? 0 "explicit submodule inspection succeeds"
[ -s $P/sub-visible.out ]; check $? 0 "…and reveals the same draft"
$B/agent spawn --role fwsub --cwd $P/fw --model haiku --brief $W/b.md --worktree feat > $P/f-sub.out 2>&1; check $? 2 "a foreign worktree with ignored submodule changes is refused"
[ "$(cat $P/foreign-feat/vendor/draft.txt)" = "submodule owner draft" ] && [ ! -e $R/stage-a/agents/fwsub ]; check $? 0 "…the submodule draft is untouched and no agent started"
exit $fail
