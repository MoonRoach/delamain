#!/bin/bash
# Review fixes of 0.2.0: a broken or dangling lock-rules.json never switches the guard off, `kinds` is validated,
# a bad AGENT_HUB_SEND_CAP costs a warning (not every tool), takeover adds no wildcard main-merge,
# AGENT_HUB_TAKE_MAIN_MERGE, AGENT_HUB_JWAIT_MATCH, CLAUDE_BIN=desktop, HUB-NOTES.md, worktree checkouts,
# `lock release` from another directory. Positive and negative controls for each.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
P=$(mktemp -d); REPO=$P/webapp; OUT=$P/outside; WT=$P/webapp-wt
mkdir -p $REPO/.git $REPO/.agent-hub $OUT $WT/.agent-hub
printf 'gitdir: %s/.git/worktrees/wt\n' $REPO > $WT/.git
ME=aaaaaaaa-0000-4000-8000-000000000001; OTHER=bbbbbbbb-0000-4000-8000-000000000002
hook(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":sys.argv[2],"cwd":sys.argv[3],"tool_input":{"command":sys.argv[1]}}))' "$1" "$2" "$3" | python3 $HOOKS/board_locks.py; }
deny(){ hook "$@" 2>/dev/null | grep -q '"permissionDecision": "deny"'; }
GOOD_HOME='{"rules": [{"match": "^helm upgrade\\b", "kinds": ["deploy-window"], "action": "helm rollout"}]}'
echo "$GOOD_HOME" > $R/lock-rules.json
CLAUDE_CODE_SESSION_ID=$OTHER $B/lock take deploy-window --repo '*' --until +2h --why "release" --owner-name "release hub" >/dev/null
CLAUDE_CODE_SESSION_ID=$OTHER $B/lock take main-merge --repo '*' --until +2h --why "merge train" --owner-name "steward" >/dev/null
GOOD_REPO='{"rules": [{"match": "^make release\\b", "kinds": ["deploy-window"], "action": "release"}]}'
GOOD_HOME='{"rules": [{"match": "^helm upgrade\\b", "kinds": ["deploy-window"], "action": "helm rollout"}]}'
echo "$GOOD_HOME" > $R/lock-rules.json

# ---- a broken repository file: skipped with a warning; built-ins and the home file still guard
echo '{"rules": [' > $REPO/.agent-hub/lock-rules.json
deny "gh pr merge 3" $ME $REPO; check $? 0 "broken repository rules: the built-in merge guard still denies"
deny "helm upgrade app ./chart" $ME $REPO; check $? 0 "…and the home file's rules still apply"
hook "make release" $ME $REPO > $P/b1.out 2> $P/b1.err; check $? 0 "…exit 0"
grep -q 'lock rules skipped' $P/b1.err && grep -q '"systemMessage": "board_locks: lock rules skipped' $P/b1.out
check $? 0 "…the broken file is named on stderr and to the user"
grep -q 'permissionDecision' $P/b1.out; check $? 1 "…and the broken file's own rule cannot apply (no decision)"
echo "$GOOD_REPO" > $REPO/.agent-hub/lock-rules.json
hook "make release" $ME $REPO > $P/b2.out 2> $P/b2.err; grep -q '"deny"' $P/b2.out && ! grep -q systemMessage $P/b2.out && [ ! -s $P/b2.err ]
check $? 0 "negative: a valid file denies, without a warning"
deny "make build" $ME $REPO; check $? 1 "negative: an unguarded command passes"

# ---- kinds validation: a string, an unknown kind, an empty list
for bad in '"deploy-window"' '["deploy_window"]' '[]'; do
  printf '{"rules": [{"match": "^make release\\\\b", "kinds": %s}]}\n' "$bad" > $REPO/.agent-hub/lock-rules.json
  hook "make release" $ME $REPO > $P/k.out 2> $P/k.err
  grep -q 'kind' $P/k.err; check $? 0 "kinds $bad: the file is refused with a reason"
  deny "gh pr merge 3" $ME $REPO; check $? 0 "kinds $bad: built-ins still guard"
done
printf '{"rules": [{"match": "^make (release", "kinds": ["stage"]}]}\n' > $REPO/.agent-hub/lock-rules.json
hook "make release" $ME $REPO 2> $P/re.err >/dev/null; grep -q 'bad regex' $P/re.err; check $? 0 "a bad regex is named"
echo "$GOOD_REPO" > $REPO/.agent-hub/lock-rules.json

# ---- a broken home file: the repository file and built-ins still guard everywhere
echo '{"rules": [{"kinds": ["stage"]}]}' > $R/lock-rules.json
deny "make release" $ME $REPO; check $? 0 "broken home file: the repository rule still denies"
deny "git push origin HEAD:main" $ME $OUT; check $? 0 "…a built-in push guard still denies outside any repository"
hook "helm upgrade x" $ME $OUT 2> $P/h.err >/dev/null; grep -q "$R/lock-rules.json: rule 1" $P/h.err; check $? 0 "…the home file is named"

# ---- a dangling symlink and a missing $AGENT_HUB_LOCK_RULES are reported, not silently ignored
rm $R/lock-rules.json; ln -s $P/gone/lock-rules.json $R/lock-rules.json
hook "helm upgrade x" $ME $OUT > $P/d.out 2> $P/d.err; grep -q 'symlink to a missing file' $P/d.err && grep -q systemMessage $P/d.out
check $? 0 "a dangling home symlink is reported"
rm $R/lock-rules.json
hook "helm upgrade x" $ME $OUT > $P/n.out 2> $P/n.err; [ ! -s $P/n.out ] && [ ! -s $P/n.err ]
check $? 0 "negative: no home file at all is silent (nothing was configured)"
AGENT_HUB_LOCK_RULES=$P/nope.json hook "helm upgrade x" $ME $OUT 2> $P/e.err >/dev/null
grep -q 'AGENT_HUB_LOCK_RULES) does not exist' $P/e.err; check $? 0 "a missing \$AGENT_HUB_LOCK_RULES is reported"
echo "$GOOD_HOME" > $P/alt.json
AGENT_HUB_LOCK_RULES=$P/alt.json deny "make release" $ME $REPO; check $? 0 "AGENT_HUB_LOCK_RULES with a repository file: the repository rule applies"
AGENT_HUB_LOCK_RULES=$P/alt.json deny "helm upgrade x" $ME $REPO; check $? 0 "…and the AGENT_HUB_LOCK_RULES rule too"

# ---- a worktree checkout (.git is a file) reads its own .agent-hub/
echo '{"rules": [{"match": "^make wt-deploy\\b", "kinds": ["deploy-window"]}]}' > $WT/.agent-hub/lock-rules.json
deny "make wt-deploy" $ME $WT; check $? 0 "worktree: its .agent-hub/lock-rules.json applies"
deny "make wt-deploy" $ME $REPO; check $? 1 "negative: not in the main checkout, which has its own file"
check "$(cd $WT && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.project_dir())' "$B")" "$(cd $WT && pwd -P)" "worktree: project_dir stops at the .git file"
rm -f $R/board.md

# ---- a bad AGENT_HUB_SEND_CAP: every tool still runs, with a warning and the default
echo '{"AGENT_HUB_SEND_CAP": "ten"}' > $R/config.json
$B/jlog --stage stage-a --tag probe "still works" > /dev/null 2> $P/cap.err; check $? 0 "bad send cap: jlog still runs"
$B/roles set --stage stage-a worker cccccccc-0000-4000-8000-000000000003 --kind headless > /dev/null 2>> $P/cap.err
$B/roles budget --stage stage-a worker > $P/cap.out 2>> $P/cap.err; check $? 0 "…roles budget still runs"
grep -q '10' $P/cap.out; check $? 0 "…with the default cap"
grep -q "AGENT_HUB_SEND_CAP='ten' is not a whole number" $P/cap.err; check $? 0 "…the bad value is reported"
deny "gh pr merge 3" $ME $OUT; check $? 1 "…(no lock: no decision)"
CLAUDE_CODE_SESSION_ID=$OTHER $B/lock take main-merge --repo '*' --until +1h --why x --owner-name s >/dev/null 2>&1
deny "gh pr merge 3" $ME $OUT; check $? 0 "…and the lock hook still denies"
check "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.MESSAGE_CAP)' "$B" 2>/dev/null)" 10 "…MESSAGE_CAP falls back to 10"
echo '{"AGENT_HUB_SEND_CAP": 4}' > $R/config.json
check "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.MESSAGE_CAP)' "$B" 2>&1)" 4 "negative: a valid cap is used, silently"
rm -f $R/config.json $R/board.md

# ---- AGENT_HUB_JWAIT_MATCH: extra wake words in the digest's jwait and in the agent's clean ending
printf '{"AGENT_HUB_JWAIT_MATCH": "PENDING OWNER|NEEDS SIGNOFF"}\n' > $R/config.json
pat=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.status_pattern())' "$B")
case "$pat" in *'AWAITING ANSWER|PENDING OWNER|NEEDS SIGNOFF') r=0 ;; *) r=1 ;; esac; check $r 0 "status pattern = built-ins + AGENT_HUB_JWAIT_MATCH"
printf '{"AGENT_HUB_JWAIT_MATCH": "(unclosed"}\n' > $R/config.json
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.status_pattern())' "$B" > $P/p.out 2> $P/p.err
grep -q 'not a valid regex' $P/p.err && ! grep -q unclosed $P/p.out; check $? 0 "negative: a bad regex is reported and left out"
printf '{"AGENT_HUB_JWAIT_MATCH": "PENDING OWNER"}\n' > $R/config.json
export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
W=$P/w; mkdir -p $W; echo "brief" > $W/b.md
wait_dead(){ for i in $(seq 1 40); do $B/agent status "$1" | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
FAKE_HOLD=3 $B/agent spawn --role ru --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1
$B/jlog --tag ru "PENDING OWNER: which branch?" > /dev/null; wait_dead ru
grep -q 'EXIT ru\|ENDED ru:' $(journal stage-a); check $? 1 "an extra wake word counts as a status word (no EXIT, no ENDED line)"
rm $R/config.json
FAKE_HOLD=3 $B/agent spawn --role ru2 --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1
$B/jlog --tag ru2 "PENDING OWNER: which branch?" > /dev/null; wait_dead ru2
grep -q 'ENDED ru2: finished, no status word' $(journal stage-a); check $? 0 "negative: without the setting the same line is not a status word"

# ---- CLAUDE_BIN=desktop: the newest CLI bundled with Claude Desktop, not PATH
FH=$P/fakehome; for v in 2.1.9 2.1.10; do mkdir -p "$FH/Library/Application Support/Claude/claude-code/$v/claude.app/Contents/MacOS"; done
for v in 2.1.9 2.1.10; do printf '#!/bin/sh\necho "bundle %s" > "$PWD/which.log"\nexec python3 %s "$@"\n' $v $T/fake_claude.py > "$FH/Library/Application Support/Claude/claude-code/$v/claude.app/Contents/MacOS/claude"; chmod +x "$FH/Library/Application Support/Claude/claude-code/$v/claude.app/Contents/MacOS/claude"; done
mkdir -p $P/pathbin; printf '#!/bin/sh\necho "path" > "$PWD/which.log"\nexec python3 %s "$@"\n' $T/fake_claude.py > $P/pathbin/claude; chmod +x $P/pathbin/claude
W2=$P/w2; mkdir -p $W2/.git $W2/.agent-hub; echo brief > $W2/b.md
echo '{"CLAUDE_BIN": "desktop"}' > $W2/.agent-hub/config.json
(unset CLAUDE_BIN; HOME=$FH PATH=$P/pathbin:$PATH $B/agent spawn --role d1 --cwd $W2 --model haiku --brief $W2/b.md) > $P/d1.out 2>&1; wait_dead d1
check "$(cat $W2/which.log 2>/dev/null)" "bundle 2.1.10" "CLAUDE_BIN=desktop: the newest bundled CLI wins over PATH"
rm $W2/.agent-hub/config.json $W2/which.log
(unset CLAUDE_BIN; HOME=$FH PATH=$P/pathbin:$PATH $B/agent spawn --role d2 --cwd $W2 --model haiku --brief $W2/b.md) > /dev/null 2>&1; wait_dead d2
check "$(cat $W2/which.log 2>/dev/null)" "path" "negative: without the setting PATH comes first"
echo '{"CLAUDE_BIN": "desktop"}' > $W2/.agent-hub/config.json
(unset CLAUDE_BIN; HOME=$P/emptyhome PATH=$P/pathbin:$PATH $B/agent spawn --role d3 --cwd $W2 --model haiku --brief $W2/b.md) > $P/d3.out 2>&1
check $? 1 "CLAUDE_BIN=desktop without a bundle: spawn fails"
grep -q 'no CLI bundled with Claude Desktop' $P/d3.out; check $? 0 "…and says why"
unset HUB_TAG CLAUDE_BIN

# ---- lock release from another directory finds this session's only lock of the kind
printf '{"AGENT_HUB_DEFAULT_REPO": "webapp"}\n' > $REPO/.agent-hub/config.json
printf '{"resources": {"stage": "staging"}}\n' > $REPO/.agent-hub/lock-rules.json
(cd $REPO && CLAUDE_CODE_SESSION_ID=$ME $B/lock take stage --until +1h --why x) > /dev/null
(cd $OUT && CLAUDE_CODE_SESSION_ID=$ME $B/lock release stage) > $P/rel.out
grep -q 'released: stage (webapp)' $P/rel.out && ! grep -q '"kind": "stage"' $R/board.md; check $? 0 "release from outside the repository finds the lock (webapp)"
(cd $REPO && CLAUDE_CODE_SESSION_ID=$ME $B/lock take stage --until +1h --why x) > /dev/null
(cd $OUT && CLAUDE_CODE_SESSION_ID=$ME $B/lock release stage --repo '*') > $P/rel2.out
grep -q 'no stage (\*) lock' $P/rel2.out && grep -q '"kind": "stage"' $R/board.md; check $? 0 "negative: an explicit --repo is taken literally"
rm -f $R/board.md

# ---- hub takeover: no wildcard main-merge; AGENT_HUB_TAKE_MAIN_MERGE; free main-merge note; HUB-NOTES.md
export CLAUDE_SESSIONS_DIR=$P/sessions; mkdir -p $CLAUDE_SESSIONS_DIR/a/b
PREV=12121212-1212-4121-8121-121212121212; PREV_CLI=34343434-3434-4343-8343-343434343434; NEW_CLI=eeeeeeee-7777-4777-8777-777777777777
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub #4"}' $PREV $PREV_CLI > $CLAUDE_SESSIONS_DIR/a/b/local_$PREV.json
tk_setup(){
  new_home; R=$AGENT_HUB_HOME; mkdir -p $R/stage-a/coordinator/work
  python3 -c 'import json,sys; json.dump({"version":1,"roles":{"hub":{"session":"local_"+sys.argv[2],"cli_session_id":sys.argv[3],"kind":"desktop","tag":"hub-4","title":"Hub #4"}},"retired":[],"sends":[]}, open(sys.argv[1],"w"))' $R/stage-a/roles.json $PREV $PREV_CLI
  [ "$1" = prev-mm ] && python3 - "$R/board.md" "$PREV_CLI" <<'PY'
import json, sys
row = {"kind": "main-merge", "repo": "webapp", "owner_name": "Hub #4", "session_id": sys.argv[2],
       "until": "2099-12-31T23:59:00+00:00", "why": "stage hub", "taken_at": "2026-09-29T14:00:00+00:00"}
open(sys.argv[1], "w").write("# b\n\n```locks\n" + json.dumps(row) + "\n```\n")
PY
  return 0
}
mm(){ python3 - "$R/board.md" <<'PY'
import json, re, sys
try:
    t = open(sys.argv[1]).read()
except FileNotFoundError:
    print("-"); sys.exit()
rows = [json.loads(l) for l in re.search(r"```locks\n(.*?)```", t, re.S).group(1).splitlines() if l.strip()]
print(",".join(sorted(f"{r['repo']}:{r['session_id'][:4]}" for r in rows if r["kind"] == "main-merge")) or "-")
PY
}
tk_setup prev-mm
(cd $OUT && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --take-main-merge) > $P/t1.out 2>&1; check $? 0 "takeover from outside the repository with --take-main-merge"
check "$(mm)" "webapp:eeee" "…takes the previous hub's main-merge (webapp) and adds no wildcard one"
grep -q 'no AGENT_HUB_DEFAULT_REPO here' $P/t1.out; check $? 0 "…and says the hub repo is unknown here"
tk_setup none
(cd $OUT && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --take-main-merge) > /dev/null 2>&1
check "$(mm)" "*:eeee" "negative control: with no main-merge anywhere the free * lock is taken (documented)"
mkdir -p $P/shop/.git
tk_setup none
(cd $P/shop && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --take-main-merge) > $P/t2b.out 2>&1
check "$(mm)" "shop:eeee" "inside a git checkout without AGENT_HUB_DEFAULT_REPO the free main-merge is the repository's, not *"
tk_setup none
(cd $P/shop && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > $P/t2c.out 2>&1
grep -q 'nobody holds main-merge' $P/t2c.out; check $? 1 "…and without the flag nothing is nudged about a repository that never opted in"
tk_setup none; printf '{"AGENT_HUB_DEFAULT_REPO": "webapp", "AGENT_HUB_TAKE_MAIN_MERGE": "true"}\n' > $REPO/.agent-hub/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > $P/t3.out 2>&1
check "$(mm)" "webapp:eeee" "AGENT_HUB_TAKE_MAIN_MERGE=true: the hub repo's free main-merge is taken without the flag"
tk_setup none; printf '{"AGENT_HUB_DEFAULT_REPO": "webapp"}\n' > $REPO/.agent-hub/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > $P/t4.out 2>&1
check "$(mm)" "-" "negative: without the setting or the flag nothing is taken"
grep -q 'nobody holds main-merge (webapp)' $P/t4.out; check $? 0 "…and the digest says nobody holds main-merge"
grep -q 'no takeover.sh in the config layers' $P/t4.out; check $? 0 "a missing takeover.sh is said, not silent"
grep -q 'Hub notes of this project' $P/t4.out; check $? 1 "negative: no HUB-NOTES.md, no pointer"
echo "# notes" > $REPO/.agent-hub/HUB-NOTES.md
tk_setup none; (cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --dry-run) > $P/t5.out 2>&1
grep -q "Hub notes of this project — read before planning: $(cd $REPO && pwd -P)/.agent-hub/HUB-NOTES.md" $P/t5.out; check $? 0 "HUB-NOTES.md is pointed at in the digest"
printf '{"AGENT_HUB_JWAIT_MATCH": "PENDING OWNER"}\n' > $R/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --dry-run) > $P/t6.out 2>&1
grep -q -- "--hub-events" $P/t6.out && ! grep -q -- "--match" $P/t6.out; check $? 0 "the digest's jwait resolves AGENT_HUB_JWAIT_MATCH through --hub-events"
grep -q -- "--stream --note" $P/t6.out && ! grep -q -- "jwait .*--for " $P/t6.out; check $? 0 "a Claude hub's digest jwait streams under a Monitor (no --for)"
grep -q "the command of one Monitor, timeout_ms 1800000" $P/t6.out; check $? 0 "…and the digest says so"
(cd $REPO && AGENT_HUB_ENGINE=codex $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --dry-run) > $P/t6c.out 2>&1
grep -q -- "--for 50m --note" $P/t6c.out && ! grep -q -- "--stream" $P/t6c.out; check $? 0 "a Codex hub's digest jwait waits 50m by default (the prompt cache lives 1 h)"
(cd $REPO && AGENT_HUB_ENGINE=codex AGENT_HUB_JWAIT_FOR=40m $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --dry-run) > $P/t6b.out 2>&1
grep -q -- "--for 40m --note" $P/t6b.out && ! grep -q -- "--for 50m" $P/t6b.out; check $? 0 "a Codex hub's digest jwait carries AGENT_HUB_JWAIT_FOR"

# ---- delta review: N1 (another repo's main-merge of the predecessor does not hide the hub repo's free one),
#      N2 (JSON boolean settings), N3 (release with two own locks of the kind names them)
tk_setup none; python3 - "$R/board.md" "$PREV_CLI" <<'PY2'
import json, sys
row = {"kind": "main-merge", "repo": "mobile", "owner_name": "Hub #4", "session_id": sys.argv[2],
       "until": "2099-12-31T23:59:00+00:00", "why": "stage hub", "taken_at": "2026-09-29T14:00:00+00:00"}
open(sys.argv[1], "w").write("# b\n\n```locks\n" + json.dumps(row) + "\n```\n")
PY2
printf '{"AGENT_HUB_DEFAULT_REPO": "webapp", "AGENT_HUB_TAKE_MAIN_MERGE": "true"}\n' > $REPO/.agent-hub/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > $P/n1.out 2>&1
check "$(mm)" "mobile:eeee,webapp:eeee" "N1: the predecessor's main-merge (mobile) does not stop taking the hub repo's free one (webapp)"
tk_setup prev-mm
(cd $OUT && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI --take-main-merge) > $P/n1b.out 2>&1
grep -q 'main-merge (\*) was wanted but not taken' $P/n1b.out; check $? 0 "N1: a wanted main-merge that is not taken is said"
tk_setup none; printf '{"AGENT_HUB_DEFAULT_REPO": "webapp", "AGENT_HUB_TAKE_MAIN_MERGE": true}\n' > $REPO/.agent-hub/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > $P/n2.out 2>&1
check "$(mm)" "webapp:eeee" "N2: a JSON boolean true is accepted"
grep -q 'must be a string' $P/n2.out; check $? 1 "…without a warning"
tk_setup none; printf '{"AGENT_HUB_DEFAULT_REPO": "webapp", "AGENT_HUB_TAKE_MAIN_MERGE": false}\n' > $REPO/.agent-hub/config.json
(cd $REPO && $B/hub takeover --stage stage-a --n 5 --session $NEW_CLI) > /dev/null 2>&1
check "$(mm)" "-" "N2 negative: a JSON boolean false takes nothing"
rm -f $R/board.md
printf '{"resources": {"stage": "staging"}}\n' > $P/stage-rules.json
(cd $OUT && AGENT_HUB_LOCK_RULES=$P/stage-rules.json CLAUDE_CODE_SESSION_ID=$ME $B/lock take stage --repo webapp --until +1h --why x) > /dev/null
(cd $OUT && AGENT_HUB_LOCK_RULES=$P/stage-rules.json CLAUDE_CODE_SESSION_ID=$ME $B/lock take stage --repo mobile --until +1h --why x) > /dev/null
(cd $OUT && CLAUDE_CODE_SESSION_ID=$ME $B/lock release stage) > $P/n3.out 2>&1; rc=$?
check $rc 1 "N3: release without --repo and two own locks of the kind: exit 1"
grep -q 'stage (webapp)' $P/n3.out && grep -q 'stage (mobile)' $P/n3.out && grep -q -- '--repo' $P/n3.out; check $? 0 "…names both and says --repo"
check "$(grep -c '"kind": "stage"' $R/board.md)" 2 "…and releases nothing"
exit $fail
