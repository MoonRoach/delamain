#!/bin/bash
# agent desktop-idle, the Desktop block of agent-top and the note of `hub close`: idle Claude Desktop sessions that still hold
# processes, and which of them are safe to archive. Fixtures: Desktop's session records, the CLI's pid records, real stand-in
# process trees (a parent with a child), throw-away repositories with a GitHub-looking and a GitLab-looking origin (a remote
# ref moved by hand stands for "pushed"), stub `gh` / `glab` on PATH. Every rule has a control: break its condition and the
# session leaves the list, fix it and the session is back.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HUB_STAGE=shop HUB_TAG=hub-test
P=$(mktemp -d); STUB=$P/stub; FORGE=$P/forge; mkdir -p $STUB $FORGE
export CLAUDE_CONFIG_DIR=$P/claude CLAUDE_SESSIONS_DIR=$P/desk GH_STUB_DIR=$FORGE
FX="python3 $T/desktop_idle_fixture.py"
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill $p 2>/dev/null; done; test_cleanup' EXIT
G(){ git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
# a stub gh / glab: open requests of a branch come from $GH_STUB_DIR/<branch, / as _>.json (else []); every call is logged;
# GH_STUB_FAIL=1 makes both fail, GH_STUB_HANG=1 makes them hang
for tool in gh glab; do
  cat > $STUB/$tool <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "$GH_STUB_DIR/calls.log"
[ -n "${GH_STUB_FAIL:-}" ] && { echo "not logged in" >&2; exit 4; }
[ -n "${GH_STUB_HANG:-}" ] && exec sleep 600
state=open
while [ $# -gt 0 ]; do case "$1" in --head|--source-branch) head=$2;; --state) state=$2;; --merged) state=merged;; esac; shift; done
f="$GH_STUB_DIR/$(echo "$head" | tr / _).json"; [ $state = merged ] && f="$GH_STUB_DIR/$(echo "$head" | tr / _).merged.json"
[ -f "$f" ] && cat "$f" || echo '[]'
EOF
  chmod +x $STUB/$tool
done
calls(){ [ -f $FORGE/calls.log ] && wc -l < $FORGE/calls.log | tr -d ' ' || echo 0; }
# a repository whose origin looks like $2 (the remote refs are moved by hand: pushed BRANCH)
mkrepo(){ git init -q -b main $1; G -C $1 commit -q --allow-empty -m init; git -C $1 remote add origin $2
          git -C $1 update-ref refs/remotes/origin/main HEAD; }
REPO=$P/app; GL=$P/gl; mkrepo $REPO https://github.com/acme/app.git; mkrepo $GL git@gitlab.example.com:acme/gl.git
pushed(){ git -C $1 update-ref refs/remotes/origin/$2 "$(git -C $1 rev-parse $2)"; }
# wt REPO NAME: a worktree on branch feat/NAME from origin/main, pushed (clean: nothing to lose)
wt(){ git -C $1 worktree add -q -b feat/$2 $1/.wt/$2 refs/remotes/origin/main; pushed $1 feat/$2; }
# session NAME STATUS IDLE_MIN CWD BRANCH [archived] [exempt]: a Desktop record, the CLI's pid record and a live process tree
session(){
  local n=$1 st=$2 idle=$(( $3 * 60 )); shift 3
  $FX proc & local pid=$!; PIDS+=($pid)
  $FX cli $CLAUDE_CONFIG_DIR $pid local_$n $st 2 $idle
  $FX desk $CLAUDE_SESSIONS_DIR local_$n cli-$n "title of $n" "$1" "$2" $idle "${@:3}"
}
wt $REPO clean; wt $REPO dirty; wt $REPO ahead; wt $REPO pr; wt $REPO recent; wt $REPO hub; wt $REPO shared; wt $REPO exempt
wt $REPO caller; wt $REPO archived; wt $REPO busy; wt $GL glclean; wt $GL glmr
echo scratch > $REPO/.wt/dirty/untracked.txt
echo a > $REPO/.wt/ahead/a.txt; G -C $REPO/.wt/ahead add a.txt; G -C $REPO/.wt/ahead commit -q -m "a: not pushed"
echo '[{"number": 7, "url": "https://github.com/acme/app/pull/7"}]' > $FORGE/feat_pr.json
echo '[{"iid": 3, "web_url": "https://gitlab.example.com/acme/gl/-/merge_requests/3"}]' > $FORGE/feat_glmr.json
session clean idle 1200 $REPO/.wt/clean feat/clean         # 20 h
session dirty idle 1800 $REPO/.wt/dirty feat/dirty         # 30 h
session ahead idle 1800 $REPO/.wt/ahead feat/ahead
session pr idle 1800 $REPO/.wt/pr feat/pr
session busy busy 2400 $REPO/.wt/busy feat/busy            # working now: never listed
session recent idle 60 $REPO/.wt/recent feat/recent        # 1 h: below the limit
session hub idle 2400 $REPO/.wt/hub feat/hub               # a registered hub looks idle between events
session sharea idle 3000 $REPO/.wt/shared feat/shared      # shares its directory with a session that is not idle long
session shareb idle 60 $REPO/.wt/shared feat/shared
session gone idle 3000 $P/missing ""
session exempt idle 3000 $REPO/.wt/exempt feat/exempt exempt
session caller idle 3000 $REPO/.wt/caller feat/caller      # the session running the command
session archived idle 3000 $REPO/.wt/archived feat/archived archived
session glclean idle 3000 $GL/.wt/glclean feat/glclean
session glmr idle 3000 $GL/.wt/glmr feat/glmr
# a stale pid record (the process is gone) and a recycled pid (alive, but it started long after the record says)
true & DEAD=$!; wait $DEAD
$FX cli $CLAUDE_CONFIG_DIR $DEAD local_stale idle 90000 90000
$FX desk $CLAUDE_SESSIONS_DIR local_stale cli-stale "title of stale" $REPO/.wt/clean feat/clean 90000
$FX proc & RECYCLED=$!; PIDS+=($RECYCLED)
$FX cli $CLAUDE_CONFIG_DIR $RECYCLED local_recycled idle 864000 90000
$FX desk $CLAUDE_SESSIONS_DIR local_recycled cli-recycled "title of recycled" $REPO/.wt/clean feat/clean 90000
mkdir -p $R/shop; echo '{"version":1,"roles":{"hub":{"session":"local_hub","cli_session_id":"cli-hub","tag":"hub-1"}},"retired":[],"sends":[]}' > $R/shop/roles.json
sleep 1   # the stand-in trees have started their children
export CLAUDE_CODE_HOST_SESSION_ID=local_caller
LIST(){ (cd $P && PATH=$STUB:$PATH $B/agent desktop-idle "$@"); }
jf(){ python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = [x for x in d["sessions"] if x["id"] == "local_" + sys.argv[2]]
if not s:
    print("MISSING")
elif sys.argv[3] == "reasons":
    print(",".join(r["code"] for r in s[0]["reasons"]) or "-")
else:
    print(json.dumps(s[0][sys.argv[3]]))
PY
}

# ---- 1. the listing: exactly the clean idle sessions are candidates
LIST --json > $P/l1.json 2> $P/l1.err; check $? 0 "desktop-idle --json works"
ids(){ LIST --ids --idle-for "${1:-12h}" 2>/dev/null | sort | tr '\n' ' '; }
check "$(ids)" "local_clean local_glclean " "--ids: exactly the clean sessions idle for 12 h or more (GitHub and GitLab remotes)"
check "$(jf $P/l1.json busy id)" MISSING "a working (busy) session is not listed"
check "$(jf $P/l1.json recent id)" MISSING "a session idle for less than the limit is not listed"
check "$(jf $P/l1.json shareb id)" MISSING "…nor the active session that shares a directory"
check "$(jf $P/l1.json archived id)" MISSING "an archived session is not listed, though a process still runs"
check "$(jf $P/l1.json stale id)" MISSING "a pid record of a dead process is ignored"
check "$(jf $P/l1.json recycled id)" MISSING "a recycled pid (another process, started later) is ignored"
check "$(jf $P/l1.json dirty reasons)" dirty "dirty: an untracked file keeps the session off the list"
check "$(jf $P/l1.json ahead reasons)" unpushed "unpushed: a commit on no remote"
check "$(jf $P/l1.json pr reasons)" pr "open pull request (gh)"
check "$(jf $P/l1.json glmr reasons)" pr "open merge request (glab, a GitLab remote)"
check "$(jf $P/l1.json hub reasons)" role "a role registered in a hub home"
check "$(jf $P/l1.json sharea reasons)" shared "a directory another, active session uses"
check "$(jf $P/l1.json gone reasons)" gone "a working directory that is gone"
check "$(jf $P/l1.json exempt reasons)" exempt "marked exempt by Desktop"
check "$(jf $P/l1.json caller reasons)" self "the session running the command"
check "$(jf $P/l1.json clean reasons)" - "the clean session has no reason against it"
check "$(jf $P/l1.json clean procs)" 3 "memory: the CLI and its two children are counted (3 processes)"
python3 -c "import json,sys; d=json.load(open('$P/l1.json')); s=[x for x in d['sessions'] if x['id']=='local_clean'][0]; sys.exit(0 if s['rss_kb']>0 and d['candidate_rss_kb']>0 and 'sleep' in s['other_processes'] else 1)"
check $? 0 "…with their resident memory, and the child that is not an MCP server is named"
check "$(python3 -c "import json; print(' '.join(sorted(json.load(open('$P/l1.json'))['candidate_ids'])))")" "local_clean local_glclean" "--json: candidate_ids"
LIST > $P/l1.txt 2>&1; grep -q 'Clean, to archive (2' $P/l1.txt && grep -q 'local_dirty' $P/l1.txt && grep -q '1 changed file' $P/l1.txt; check $? 0 "the text listing names the clean ones and why the others stay"
grep -q 'Not touched (' $P/l1.txt; check $? 0 "…under 'Not touched'"
check "$(LIST --idle-for 25h --ids | tr '\n' ' ')" "local_glclean " "--idle-for 25h: the 20 h session is not idle long enough"
LIST --json --ids > /dev/null 2>&1; check $? 2 "--json with --ids is a usage error"
python3 -I - "$B" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import desktop_idle as d
assert d.proc_name("npm exec @upstash/context7-mcp --api-key SECRET123") == "npm"
assert d.proc_name("/Users/x/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude") == "claude"
assert d.proc_name("build/hub-viz") == "hub-viz"
assert d.remote_host("git@github.com:acme/app.git") == "github.com"
assert d.remote_host("https://user:pw@gitlab.example.com/acme/gl.git") == "gitlab.example.com"
assert d.remote_host("ssh://git@host.example:2222/x/y.git") == "host.example"
PY
check $? 0 "a command line (with a key in it) is never reduced to more than the executable's name; remote hosts parse"
ps -ww -axo command= | grep -q 'S3CR3T'; check $? 0 "control: a retitled stand-in process shows the key in ps's own output"
grep -q 'S3CR3T\|api-key' $P/l1.json $P/l1.txt; check $? 1 "…and none of it reaches the output"

# ---- 2. controls: each rule can be broken and fixed
touch $REPO/.wt/clean/new.txt
check "$(ids)" "local_glclean " "control: a new file in the clean worktree removes it from the list"
rm $REPO/.wt/clean/new.txt
check "$(ids)" "local_clean local_glclean " "…and removing the file brings it back"
echo c > $REPO/.wt/clean/c.txt; G -C $REPO/.wt/clean add c.txt; G -C $REPO/.wt/clean commit -q -m "c"
check "$(ids)" "local_glclean " "control: a commit on no remote removes it"
pushed $REPO feat/clean
check "$(ids)" "local_clean local_glclean " "…and pushing it brings it back"
echo '[{"number": 9, "url": "u"}]' > $FORGE/feat_clean.json
check "$(ids)" "local_glclean " "control: an open pull request removes it"
rm $FORGE/feat_clean.json
check "$(ids)" "local_clean local_glclean " "…and closing it brings it back"
GH_STUB_FAIL=1 LIST --ids > $P/fail.ids 2>/dev/null; check "$(cat $P/fail.ids | tr '\n' ' ')" "" "control: when gh and glab fail, nothing is safe to archive"
GH_STUB_FAIL=1 LIST --json > $P/fail.json 2>/dev/null
check "$(jf $P/fail.json clean reasons)" unknown "…the session is 'unknown', not clean"
grep -q 'failed on github.com' $P/fail.json; check $? 0 "…and the reason names the tool and the host"
LIST --no-gh --ids > $P/nogh.ids 2>/dev/null; check "$(cat $P/nogh.ids | tr '\n' ' ')" "" "--no-gh: open requests unchecked, nothing safe to archive"
PATH=$STUB:$PATH CLAUDE_CODE_HOST_SESSION_ID= $B/agent desktop-idle --json > $P/noself.json 2>/dev/null
check "$(jf $P/noself.json caller reasons)" - "control: not the caller, the same session is clean"
rm $R/shop/roles.json
check "$(ids)" "local_clean local_glclean local_hub " "control: unregistered, the hub's session is clean"

# ---- 3. agent-top: the summary block and --json, one check kept in the cache for a while
echo '{"version":1,"roles":{"hub":{"session":"local_hub","cli_session_id":"cli-hub","tag":"hub-1"}},"retired":[],"sends":[]}' > $R/shop/roles.json
rm -rf $R/.state; before=$(calls)
PATH=$STUB:$PATH $B/agent-top --json > $P/top1.json 2> $P/top1.err; check $? 0 "agent-top --json works"
python3 -c "import json; d=json.load(open('$P/top1.json'))['desktop_idle']; print(' '.join(sorted(d['candidate_ids'])))" > $P/top1.ids
check "$(cat $P/top1.ids)" "local_clean local_glclean" "agent-top --json: desktop_idle lists the same candidates"
mid=$(calls); [ "$mid" -gt "$before" ]; check $? 0 "…after asking the forge"
GH_STUB_FAIL=1 PATH=$STUB:$PATH $B/agent-top --json > $P/top2.json 2>/dev/null
check "$(python3 -c "import json; print(' '.join(sorted(json.load(open('$P/top2.json'))['desktop_idle']['candidate_ids'])))")" "local_clean local_glclean" "a second run within 5 minutes reads the cached answer"
check "$(calls)" "$mid" "…without calling gh or glab again"
GH_STUB_FAIL=1 AGENT_TOP_CACHE=0 PATH=$STUB:$PATH $B/agent-top --json > $P/top3.json 2>/dev/null
check "$(python3 -c "import json; print(len(json.load(open('$P/top3.json'))['desktop_idle']['candidate_ids']))")" 0 "control: without the cache the failing forge leaves nothing safe"
PATH=$STUB:$PATH AGENT_TOP_CACHE=0 $B/agent-top --once --width 130 > $P/top.txt 2>&1; check $? 0 "agent-top --once works"
grep -q 'Desktop sessions idle ≥ 12 h that hold processes' $P/top.txt; check $? 0 "the summary has the Desktop block"
grep -q 'left alone: title of dirty — idle 30 h.*1 changed file' $P/top.txt; check $? 0 "…naming a session it leaves alone with the reason"
grep -q '2 to archive' $P/top.txt; check $? 0 "…and how many are safe to archive"
mkdir -p $P/empty; (CLAUDE_CONFIG_DIR=$P/empty PATH=$STUB:$PATH AGENT_TOP_CACHE=0 $B/agent-top --once --width 130 2>&1 | grep -q 'Desktop sessions'); check $? 1 "control: no Desktop sessions, no block"

# ---- 4. hub close names the stage's idle Desktop sessions (an earlier hub shift is one) and archives nothing
mkdir -p $R/old; echo '{"version":1,"roles":{},"retired":[{"role":"hub","session":"local_clean","cli_session_id":"cli-clean","tag":"hub-1","retired_at":"2026-10-01T10:00:00+00:00"},{"role":"hub","session":"local_dirty","tag":"hub-2","retired_at":"2026-10-02T10:00:00+00:00"}],"sends":[]}' > $R/old/roles.json
PATH=$STUB:$PATH $B/hub close --stage old --why "done" > $P/close.out 2>&1; check $? 0 "hub close works"
grep -q 'Desktop sessions of stage old that are idle and hold processes: 2' $P/close.out && grep -q 'archive after the owner' $P/close.out && grep -q 'local_clean' $P/close.out; check $? 0 "…and names the stage's idle Desktop sessions with the clean one to archive"
grep -q 'left alone: local_dirty' $P/close.out; check $? 0 "…and the one it leaves alone"
kill -0 "${PIDS[0]}" 2>/dev/null; check $? 0 "…and stops nothing (the session's process still runs)"
grep -q 'closed stage old' $P/close.out; check $? 0 "the stage is closed all the same"
mkdir -p $R/none; echo '{"version":1,"roles":{},"retired":[],"sends":[]}' > $R/none/roles.json
PATH=$STUB:$PATH $B/hub close --stage none --why "done" > $P/close2.out 2>&1; grep -q 'Desktop sessions' $P/close2.out; check $? 1 "control: a stage without Desktop sessions has no such line"

# ---- 5. a squash-merged branch: its commits are on no remote ref, and still safe because a merged request holds them
wt $REPO merged; wt $GL glmerged
for w in $REPO/.wt/merged $GL/.wt/glmerged; do echo m > $w/m.txt; G -C $w add m.txt; G -C $w commit -q -m "m"; done
sha=$(git -C $REPO/.wt/merged rev-parse HEAD); gsha=$(git -C $GL/.wt/glmerged rev-parse HEAD)
echo "[{\"number\": 11, \"url\": \"u\", \"headRefOid\": \"$sha\", \"baseRefName\": \"main\", \"mergedAt\": \"2026-10-20T10:00:00Z\"}]" > $FORGE/feat_merged.merged.json
echo "[{\"iid\": 5, \"web_url\": \"u\", \"sha\": \"$gsha\", \"target_branch\": \"main\", \"merged_at\": \"2026-10-20T10:00:00Z\"}]" > $FORGE/feat_glmerged.merged.json
session merged idle 1500 $REPO/.wt/merged feat/merged
session glmerged idle 1500 $GL/.wt/glmerged feat/glmerged
sleep 1
LIST --json > $P/l5.json 2>/dev/null
check "$(jf $P/l5.json merged reasons)" - "a branch whose commits are inside a merged pull request (gh) is clean"
check "$(jf $P/l5.json glmerged reasons)" - "…and so is one inside a merged merge request (glab)"
echo n > $REPO/.wt/merged/n.txt; G -C $REPO/.wt/merged add n.txt; G -C $REPO/.wt/merged commit -q -m "n: after the merge"
LIST --json > $P/l5b.json 2>/dev/null
check "$(jf $P/l5b.json merged reasons)" unpushed "control: a commit made after the merged request's head is unpushed work"
grep -q 'was merged, but the branch has commits it does not contain' $P/l5b.json; check $? 0 "…and the reason says why the merged request does not cover it"

# ---- 6. two clean idle sessions in one linked worktree: both stay, each names the other (archiving one cleans it up under the other)
wt $REPO twin
session twin1 idle 1500 $REPO/.wt/twin feat/twin
session twin2 idle 1500 $REPO/.wt/twin feat/twin
sleep 1
LIST --json > $P/l6.json 2>/dev/null
check "$(jf $P/l6.json twin1 reasons)" shared "twin: the first of two clean sessions in one worktree is not offered"
check "$(jf $P/l6.json twin2 reasons)" shared "…nor the second"
python3 -c "import json; d=json.load(open('$P/l6.json')); s=[x for x in d['sessions'] if x['id']=='local_twin1'][0]; r=s['reasons'][0]['text']; import sys; sys.exit(0 if 'title of twin2' in r and 'cleans the worktree up for both' in r else 1)"
check $? 0 "…each names the other session and says why"
case "$(ids)" in *twin*) check 1 0 "…neither is in --ids";; *) check 0 0 "…neither is in --ids";; esac
LIST > $P/l6.txt 2>&1; grep -q 'title of twin1' $P/l6.txt && grep -q 'Not touched' $P/l6.txt; check $? 0 "…the listing names them under 'Not touched'"
$FX desk $CLAUDE_SESSIONS_DIR local_twin2 cli-twin2 "title of twin2" $REPO/.wt/twin feat/twin 90000 archived
check "$(LIST --json 2>/dev/null > $P/l6b.json; jf $P/l6b.json twin1 reasons)" - "control: once the other session is gone from the worktree, the remaining clean one is offered"
$FX desk $CLAUDE_SESSIONS_DIR local_twin2 cli-twin2 "title of twin2" $REPO/.wt/twin feat/twin 90000
# a session that is not idle for long also keeps a clean one in place (and the reason differs)
python3 -c "import json; d=json.load(open('$P/l1.json')); s=[x for x in d['sessions'] if x['id']=='local_sharea'][0]; import sys; sys.exit(0 if 'active or idle for less than the limit' in s['reasons'][0]['text'] else 1)"
check $? 0 "a worktree also used by an active session: the reason says the other is active"
# the main checkout is not cleaned up by an archive: two clean sessions there are still offered
PLAIN=$P/plain; mkrepo $PLAIN https://github.com/acme/plain.git
for n in main1 main2; do session $n idle 1500 $PLAIN main; done
sleep 1
LIST --json > $P/l6c.json 2>/dev/null
check "$(jf $P/l6c.json main1 reasons)" - "two clean sessions in the main checkout (nothing to clean up) are both offered"

# ---- 7. a hung gh or glab: 'unknown' within the time limit, never the 30 s a call used to take
export AGENT_HUB_FORGE_TIMEOUT_S=1
s0=$SECONDS; GH_STUB_HANG=1 LIST --json > $P/l7.json 2>/dev/null; took=$((SECONDS - s0))
[ $took -lt 25 ]; check $? 0 "desktop-idle with every gh / glab call hanging returns in $took s (calls limited to 1 s here)"
check "$(python3 -c "import json; print(len(json.load(open('$P/l7.json'))['candidate_ids']))")" 0 "…and nothing is offered"
check "$(jf $P/l7.json clean reasons)" unknown "…the clean session is 'unknown'"
grep -q 'gave no answer in 1 s' $P/l7.json; check $? 0 "…and the reason names the time limit"
s0=$SECONDS; GH_STUB_HANG=1 AGENT_TOP_CACHE=0 PATH=$STUB:$PATH $B/agent-top --json > $P/top7.json 2>/dev/null; took=$((SECONDS - s0))
[ $took -lt 40 ]; check $? 0 "one-shot agent-top --json with a hung gh returns in $took s, not after the call timeouts add up"
check "$(python3 -c "import json; d=json.load(open('$P/top7.json'))['desktop_idle']; print(len(d['candidate_ids']), len(d['sessions']) > 0)")" "0 True" "…with the sessions listed and none of them a candidate"
unset AGENT_HUB_FORGE_TIMEOUT_S
before=$(calls)
python3 -I - "$B" "$REPO/.wt/clean" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import desktop_idle as d
out, why = d.Forge(True, budget=0.0).open_requests(Path(sys.argv[2]), "feat/clean")
assert out is None and "too slow" in why, (out, why)
PY
PATH=$STUB:$PATH python3 -I - "$B" "$REPO/.wt/clean" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import desktop_idle as d
f = d.Forge(True, budget=0.0)
out, why = f.open_requests(Path(sys.argv[2]), "feat/clean")
assert out is None and "too slow" in why, (out, why)
out, why = d.Forge(True, budget=60.0).open_requests(Path(sys.argv[2]), "feat/clean")
assert out == [], (out, why)
PY
check $? 0 "the run's budget: once spent, a lookup answers 'unknown' without calling the forge; with budget left it asks"
check "$(( $(calls) - before ))" 1 "…(one call, the second one)"
exit $fail
